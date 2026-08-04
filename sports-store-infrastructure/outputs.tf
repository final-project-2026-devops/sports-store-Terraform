############################################
# Networking
############################################

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = module.vpc.private_subnets
}

############################################
# EKS
############################################

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "eks_cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "eks_cluster_endpoint" {
  description = "Endpoint URL of the EKS Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "eks_oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the EKS cluster (used by IRSA roles)."
  value       = module.eks.oidc_provider_arn
}

output "eks_node_security_group_id" {
  description = "Security group ID attached to the EKS managed node group."
  value       = module.eks.node_security_group_id
}

output "alb_security_group_id" {
  description = "Security group ID to attach to ALBs via the alb.ingress.kubernetes.io/security-groups annotation on Kubernetes Ingress resources."
  value       = aws_security_group.alb.id
}

output "ebs_csi_irsa_role_arn" {
  description = "IAM role ARN used by the EBS CSI driver controller service account."
  value       = module.ebs_csi_irsa_role.iam_role_arn
}

output "lb_controller_irsa_role_arn" {
  description = "IAM role ARN used by the AWS Load Balancer Controller service account."
  value       = module.lb_controller_irsa_role.iam_role_arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB in front of the cluster (the CloudFront /api/* origin). Not meant to be called directly -- use site_domain_name."
  value       = aws_lb.main.dns_name
}

output "alb_gateway_target_group_arn" {
  description = "ARN of the ALB's target group. Bind the gateway's Kubernetes Service to this via a TargetGroupBinding custom resource to actually receive traffic."
  value       = aws_lb_target_group.gateway.arn
}

output "site_domain_name" {
  description = "The stable public domain for both the frontend (/*) and the API (/api/*). This is what the frontend build's API base URL and any E2E tests should point at."
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

############################################
# DynamoDB
############################################

output "dynamodb_table_names" {
  description = "Map of service key to DynamoDB table name."
  value       = { for k, v in aws_dynamodb_table.this : k => v.name }
}

output "dynamodb_table_arns" {
  description = "Map of service key to DynamoDB table ARN."
  value       = { for k, v in aws_dynamodb_table.this : k => v.arn }
}

output "dynamodb_service_irsa_role_arns" {
  description = "Map of service key to the IRSA role ARN scoped to that service's DynamoDB table."
  value       = { for k, v in module.dynamodb_service_irsa_role : k => v.iam_role_arn }
}

output "catalog_variants_table_name" {
  description = "Name of catalog-service's second table (product variants/stock, DYNAMODB_VARIANTS_TABLE_NAME)."
  value       = aws_dynamodb_table.catalog_variants.name
}

output "catalog_variants_table_arn" {
  description = "ARN of catalog-service's second table (product variants/stock)."
  value       = aws_dynamodb_table.catalog_variants.arn
}

############################################
# ECR
############################################

output "ecr_repository_urls" {
  description = "Map of repository name to its ECR repository URL."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "ecr_repository_arns" {
  description = "Map of repository name to its ECR repository ARN."
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

############################################
# Frontend (S3 + CloudFront)
############################################

output "frontend_bucket_name" {
  description = "Name of the S3 bucket hosting the frontend static assets."
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution serving the frontend (used for cache invalidations)."
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_distribution_domain_name" {
  description = "CloudFront domain name (e.g. dXXXXXXXXXXXXX.cloudfront.net) serving the frontend."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

############################################
# Student IAM access
############################################

output "student_iam_usernames" {
  description = "Map of student name to their IAM username."
  value       = { for k, v in aws_iam_user.students : k => v.name }
}

output "student_console_signin_url" {
  description = "AWS console sign-in URL for IAM users in this account."
  value       = "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console"
}

output "student_temporary_passwords" {
  description = "Temporary console passwords (reset required on first login). Share each one only with that student, over a secure/private channel — not a group chat."
  value       = { for k, v in aws_iam_user_login_profile.students : k => v.password }
  sensitive   = true
}

############################################
# CI/CD (GitHub OIDC)
############################################

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider."
  value       = local.github_oidc_provider_arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions workflows to assume via OIDC (use with aws-actions/configure-aws-credentials)."
  value       = aws_iam_role.github_actions.arn
}
