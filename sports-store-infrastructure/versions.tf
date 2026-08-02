terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  # Terraform Cloud remote backend. VCS-driven runs are configured on the
  # workspace itself (Settings > Version Control); state locking and remote
  # execution are handled automatically by Terraform Cloud.
  cloud {
    organization = "final-project-2026-devops"

    workspaces {
      name = "sports-store-infrastructure"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Short-lived, per-apply auth token used to talk to the Kubernetes API of the
# cluster created in eks.tf. Using the AWS provider's data source (instead of
# an `exec`-based plugin) avoids any dependency on the AWS CLI being present
# in the Terraform Cloud run environment.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
