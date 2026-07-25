# AKS + ACR + Log Analytics — Terraform + GitHub Actions Demo

This repo provisions:
- **Azure Kubernetes Service (AKS)**
- **Azure Container Registry (ACR)**
- **Log Analytics Workspace (LAW)** wired to AKS via the `oms_agent` add-on (Container Insights)

...using Terraform, deployed via GitHub Actions. A Hello World Flask app is built, pushed to ACR,
and deployed to AKS behind an NGINX Ingress with a Let's Encrypt TLS certificate (HTTPS).

## Repo structure

```
terraform/           # Infra as code (RG, LAW, ACR, AKS, role assignment)
app/                  # Hello World app + Dockerfile
k8s/                  # Deployment, Service, Ingress, cert-manager ClusterIssuer
.github/workflows/    # terraform.yml (infra) and build-deploy.yml (app CI/CD)
```

## Prerequisites

- Azure subscription with Owner/Contributor access
- Azure CLI (`az`) logged in locally for the one-time bootstrap steps
- A domain name you control (needed for the Let's Encrypt HTTPS certificate)

## 1. One-time bootstrap (do this locally, before first workflow run)

### 1a. Create the Terraform remote state storage account

```bash
az group create -n rg-tfstate -l centralindia

az storage account create \
  -n tfstateaksdemo$RANDOM \
  -g rg-tfstate -l centralindia --sku Standard_LRS

az storage container create \
  --account-name <storage_account_name> -n tfstate
```
Note the resource group name, storage account name, and container name — these go into
GitHub secrets `TFSTATE_RG`, `TFSTATE_SA`, `TFSTATE_CONTAINER`.

### 1b. Create an Azure AD App Registration + OIDC federated credential
(This lets GitHub Actions log in to Azure without storing a client secret.)

```bash
az ad app create --display-name gh-actions-aks-demo
# note the appId (this is AZURE_CLIENT_ID)

az ad sp create --id <appId>

az role assignment create \
  --assignee <appId> \
  --role Contributor \
  --scope /subscriptions/<subscription_id>

az ad app federated-credential create \
  --id <appId> \
  --parameters '{
    "name": "gh-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<github_org>/<repo_name>:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 1c. Add GitHub repo secrets
`Settings > Secrets and variables > Actions`

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | App registration's appId |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `TFSTATE_RG` | `rg-tfstate` |
| `TFSTATE_SA` | storage account name from step 1a |
| `TFSTATE_CONTAINER` | `tfstate` |
| `ACR_NAME` | set after first `terraform apply` (see outputs) |
| `AKS_CLUSTER_NAME` | set after first `terraform apply` |
| `AKS_RESOURCE_GROUP` | `rg-aks-demo` (or your chosen `resource_group_name`) |

## 2. Deploy the infrastructure

Push to `main` (or run manually via **Actions > Terraform Infra > Run workflow**).
The `terraform.yml` workflow runs `init`, `validate`, `plan`, and `apply`.

After it succeeds, grab the outputs:
```bash
cd terraform
terraform output acr_name
terraform output aks_cluster_name
```
Add these values as the `ACR_NAME` and `AKS_CLUSTER_NAME` secrets (step 1c), if not already set.

## 3. Install NGINX Ingress + cert-manager on the cluster (one-time, after AKS exists)

```bash
az aks get-credentials -g rg-aks-demo -n <aks_cluster_name>

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
```

Get the ingress controller's public IP and point your domain's A record to it:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

Edit `k8s/ingress.yaml` and `k8s/cluster-issuer.yaml`, replacing:
- `__YOUR_DOMAIN__` with your actual domain (e.g. `hello.example.com`)
- `__YOUR_EMAIL__` with your email (for Let's Encrypt expiry notices)

Apply the ClusterIssuer once:
```bash
kubectl apply -f k8s/cluster-issuer.yaml
```

## 4. Build and deploy the app

Push to `main` (or run manually via **Actions > Build and Deploy App**).
The `build-deploy.yml` workflow:
1. Builds the Docker image using `az acr build` (builds directly in ACR, no local Docker needed)
2. Substitutes the ACR login server + image tag into `k8s/deployment.yaml`
3. Applies the Deployment, Service, and Ingress to AKS
4. Waits for rollout to complete

## 5. Validation

**Infra:**
```bash
az aks show -g rg-aks-demo -n <aks_cluster_name> --query provisioningState
az acr show -n <acr_name> --query provisioningState
az monitor log-analytics workspace show -g rg-aks-demo -n <law_name>
```

**Logs flowing to LAW** (Azure Portal > Log Analytics Workspace > Logs):
```kusto
ContainerLogV2
| where TimeGenerated > ago(30m)
| project TimeGenerated, PodName, LogMessage
| order by TimeGenerated desc
```

**App is running:**
```bash
kubectl get pods -l app=hello-world
kubectl get ingress hello-world
kubectl get certificate hello-world-tls   # should show READY=True once issued
```

**HTTPS works:**
```bash
curl https://<your-domain>/
# {"message": "Hello World from AKS!", ...}
```

## Human update: live HTTPS fix summary

This section is intentionally written like an operator handoff note, so the next person can understand what was broken and what was fixed in production.

### What was failing
- Browser showed certificate warnings because a trusted Let's Encrypt certificate was not getting issued.
- cert-manager HTTP-01 challenge was failing with timeout/404 during validation.

### Root cause found
- Ingress was using a self-signed issuer at one point, which is not trusted by public browsers.
- ACME issuer config was pointing to staging endpoint previously.
- Most important: Azure Load Balancer probe path for ingress was effectively checking a path that returned `404` on nodePort, which made external traffic unhealthy/unreachable even though in-cluster routing worked.

### Fixes applied
1. Switched Ingress to use `letsencrypt-prod` ClusterIssuer.
2. Updated ClusterIssuer ACME server to production (`https://acme-v02.api.letsencrypt.org/directory`).
3. Set HTTP-01 solver with `ingressClassName: nginx`.
4. Set Azure LB health probe request path on ingress controller service to `/healthz`.
5. Re-triggered certificate issuance by deleting old `hello-world-tls` Certificate resource.
6. After certificate became ready, re-enabled HTTP to HTTPS redirect.

### How HTTPS is working now
1. DNS `A` record points domain to ingress public IP.
2. NGINX Ingress receives traffic on ports `80/443`.
3. cert-manager solves HTTP-01 challenge via Ingress and gets a trusted cert from Let's Encrypt.
4. Certificate is stored in secret `hello-world-tls` and attached in Ingress TLS section.
5. Browser connects over `https://` and sees a valid public CA certificate.

### Quick checks for future debugging
```bash
kubectl get ingress -n default -o wide
kubectl get certificate,certificaterequest,order,challenge -n default
kubectl get svc ingress-nginx-controller -n ingress-nginx -o yaml
```

If issue repeats, verify these first:
- Domain still resolves to current ingress public IP.
- Ingress controller service still has annotation:
  `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz`
- Certificate status is `READY=True`.

## Notes / assumptions
- ACR pull uses AKS's managed identity (`AcrPull` role) — no registry credentials stored anywhere.
- GitHub → Azure auth uses OIDC federated credentials, not long-lived secrets.
- TLS certificate issuance requires the domain's DNS to already point at the ingress controller's
  public IP before applying the Ingress (HTTP-01 challenge needs to reach the cluster).
- Default node size (`Standard_B2s`) and node count (2) are for demo/cost purposes; adjust
  `terraform/variables.tf` for production use.
