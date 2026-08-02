# sports-store-infrastructure

Terraform infrastructure layer for **CloudCart**, a sports store microservices application.

## What this provisions

| File | Resources |
|---|---|
| `versions.tf` | Terraform Cloud backend, provider requirements/config |
| `variables.tf` | All input variables |
| `locals.tf` | Common tags, naming, AZ selection |
| `vpc.tf` | VPC across 2 AZs (public/private subnets, 1 NAT Gateway, S3 gateway endpoint) |
| `eks.tf` | EKS cluster, managed node group, IRSA, EBS CSI driver, AWS Load Balancer Controller |
| `dynamodb.tf` | 5 DynamoDB tables + per-microservice least-privilege IRSA roles |
| `ecr.tf` | 7 ECR repositories with scan-on-push + lifecycle policies |
| `frontend_s3_cloudfront.tf` | Private S3 bucket + CloudFront (OAC) for the frontend SPA |
| `iam_oidc_github.tf` | GitHub Actions OIDC provider + CI/CD IAM role |
| `outputs.tf` | All resource outputs consumed by CI/CD and downstream tooling |

## Prerequisites

- Terraform >= 1.6
- A Terraform Cloud organization/workspace (VCS-driven, remote execution)
- AWS credentials configured on the Terraform Cloud workspace (or an
  AWS provider dynamic credential/OIDC integration)

## Usage

1. Update the `cloud` block in `versions.tf` with your Terraform Cloud
   organization name.
2. Copy `terraform.tfvars.example` to `terraform.tfvars` (for local runs) or
   set the equivalent workspace variables in Terraform Cloud. At minimum,
   set `github_org` to your real GitHub organization/user.
3. `terraform init`
4. `terraform plan`
5. `terraform apply`

## Notes

- **Node authentication (`kubernetes.io/role/*` tags)**: private/public
  subnets are tagged for EKS/ELB auto-discovery as required by the AWS Load
  Balancer Controller and legacy in-tree providers.
- **Least privilege**: each microservice gets its own IRSA role scoped to
  exactly one DynamoDB table. Kubernetes ServiceAccounts must be named
  `<service>-service-sa` (e.g. `auth-service-sa`) in the `cloudcart`
  namespace (see `k8s_namespace` variable) and annotated with the matching
  role ARN from the `dynamodb_service_irsa_role_arns` output.
- **CI/CD**: the GitHub Actions IAM role trusts only the repositories listed
  in `github_allowed_repositories` via the OIDC `sub` claim — no static AWS
  access keys are used. It can push to the 7 ECR repositories, sync the
  frontend build to S3, invalidate the CloudFront distribution, and has
  cluster-admin on the EKS cluster via an access entry for deployments.
- **Custom domain**: leave `acm_certificate_arn` unset to use the default
  `*.cloudfront.net` certificate, or supply a `us-east-1` ACM certificate ARN
  plus `frontend_domain_aliases` for a branded domain.
