variable "location" {
  description = "Azure region"
  type        = string
  default     = "Central India"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "rg-assesment-test"
}

variable "prefix" {
  description = "Prefix used to name resources"
  type        = string
  default     = "aksdemo"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version (leave null to use Azure's current default)"
  type        = string
  default     = null
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 2
}

variable "vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_B2s_v2"
}

variable "acr_sku" {
  description = "ACR SKU"
  type        = string
  default     = "Basic"
}
