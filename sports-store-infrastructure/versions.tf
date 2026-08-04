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

# Auth tokens for the Kubernetes API of the cluster created in eks.tf are
# generated on demand via the `exec` plugin (instead of a single static
# token fetched via data.aws_eks_cluster_auth) so each API call gets a fresh
# token. Cluster creation + node groups can take longer than a token's
# ~15-minute TTL, so a token fetched once at the start of the run would be
# expired by the time later kubernetes_*/helm_release resources apply,
# causing 401 Unauthorized errors. Requires the AWS CLI in the Terraform
# Cloud run environment (this workspace runs on an Agent pool image that
# includes it).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
