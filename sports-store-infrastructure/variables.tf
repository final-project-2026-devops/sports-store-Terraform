############################################
# General
############################################

variable "aws_region" {
  description = "AWS region in which all resources are provisioned."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short, URL-safe project identifier used as a prefix/suffix for resource names."
  type        = string
  default     = "cloudcart"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment name (used in tags and resource naming)."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "k8s_namespace" {
  description = "Kubernetes namespace the CloudCart microservices are deployed into. Used to scope IRSA trust policies."
  type        = string
  default     = "cloudcart"
}

############################################
# Networking (VPC)
############################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread public/private subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count == 2
    error_message = "This architecture is designed for exactly 2 Availability Zones."
  }
}

############################################
# Compute (EKS)
############################################

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.30"
}

variable "eks_public_access_enabled" {
  description = "Whether the EKS API server endpoint is reachable from outside the VPC. Private access is always enabled."
  type        = bool
  default     = true
}

variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint when eks_public_access_enabled is true. Restrict this to known office/CI egress ranges in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types used by the default managed node group."
  type        = list(string)
  # t3.micro caps out at 4 pods/node (ENI limit), which isn't enough room for
  # aws-node + kube-proxy + coredns + ebs-csi + the LB controller to all
  # schedule across 2 nodes. t3.medium isn't Free Tier-eligible on this
  # account, so t3.small (11 pods/node) is the next viable step up.
  default = ["t3.small"]
}

variable "node_group_min_size" {
  description = "Minimum number of nodes in the default managed node group."
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum number of nodes in the default managed node group."
  type        = number
  default     = 4
}

variable "node_group_desired_size" {
  description = "Desired number of nodes in the default managed node group."
  type        = number
  default     = 2
}

variable "node_group_disk_size" {
  description = "Root EBS volume size (GiB) for worker nodes."
  type        = number
  default     = 50
}

variable "lb_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller (eks-charts repo)."
  type        = string
  default     = "1.8.1"
}

############################################
# Database (DynamoDB)
############################################

variable "enable_dynamodb_pitr" {
  description = "Enable point-in-time recovery on all DynamoDB tables."
  type        = bool
  default     = true
}

############################################
# Container Registry (ECR)
############################################

variable "ecr_tagged_image_count" {
  description = "Number of tagged (v*) images to retain per ECR repository before older ones expire."
  type        = number
  default     = 15
}

variable "ecr_untagged_expiry_days" {
  description = "Number of days after which untagged ECR images are expired."
  type        = number
  default     = 7
}

############################################
# Frontend (S3 + CloudFront)
############################################

variable "acm_certificate_arn" {
  description = "ACM certificate ARN (in us-east-1) for a custom CloudFront domain. Leave null to use the default *.cloudfront.net certificate."
  type        = string
  default     = null
}

variable "frontend_domain_aliases" {
  description = "Custom domain names (CNAMEs) to associate with the CloudFront distribution. Requires acm_certificate_arn to be set."
  type        = list(string)
  default     = []
}

variable "cloudfront_price_class" {
  description = "CloudFront price class controlling edge location coverage."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be one of PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

############################################
# Student access (least-privilege IAM users + EKS access)
############################################

variable "students" {
  description = "Teammates to provision least-privilege IAM users + EKS access for. Set real values in terraform.tfvars (gitignored) — do not commit names/emails here."
  type = list(object({
    name  = string
    email = string
  }))
  default = []
}

variable "owner_email" {
  description = "Project owner's email, included alongside student emails in budget alert notifications."
  type        = string
  default     = ""
}

############################################
# Budgets
############################################

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget (USD). Triggers email alerts at 50/80/100% actual spend and 100% forecasted spend."
  type        = number
  default     = 150
}

############################################
# CI/CD (GitHub OIDC)
############################################

variable "create_github_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider (token.actions.githubusercontent.com). AWS allows only one per account/issuer URL, so set this to false and rely on the data-source lookup if a provider already exists (e.g. created by another stack or a prior apply)."
  type        = bool
  default     = true
}

variable "github_org" {
  description = "GitHub organization or user that owns the CloudCart repositories."
  type        = string
  default     = "your-github-org"
}

variable "github_allowed_repositories" {
  description = "List of GitHub repository names (under github_org) allowed to assume the CI/CD IAM role via OIDC."
  type        = list(string)
  default = [
    "sports-store-infrastructure",
    "sports-store-frontend",
    "sports-store-gateway",
    "sports-store-auth-service",
    "sports-store-catalog-service",
    "sports-store-cart-service",
    "sports-store-order-service",
    "sports-store-payment-service",
  ]
}
