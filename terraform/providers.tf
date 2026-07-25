terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }

  # Remote state - create this storage account manually ONE TIME before first run
  # (see README "Bootstrap remote state" section)
  backend "azurerm" {
    # Values are supplied via -backend-config in the GitHub Actions workflow,
    # so this block is intentionally left mostly empty here.
    key = "aks-demo.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
