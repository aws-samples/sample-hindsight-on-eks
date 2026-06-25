terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", var.aws_profile, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", var.aws_profile, "--region", var.aws_region]
    }
  }
}

locals {
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }

  # true when provisioning the cluster on EKS Auto Mode rather than Fargate.
  auto_mode = var.compute_mode == "auto"

  # cluster_compute_config passed to the EKS module. In Auto Mode this is the
  # populated object; in Fargate mode it must be an EMPTY map so the module omits
  # the compute_config block entirely (EKS requires computeConfig,
  # kubernetesNetworkConfig, and blockStorage to be all-enabled or all-disabled,
  # and the module only renders network/storage when compute_config.enabled is
  # true). A `for` with an `if` guard yields a truly empty map in Fargate mode
  # without the ternary type-consistency error that `... ? {…} : {}` causes.
  cluster_compute_config = {
    for k, v in {
      enabled    = true
      node_pools = ["general-purpose", "system"]
    } : k => v if local.auto_mode
  }
}
