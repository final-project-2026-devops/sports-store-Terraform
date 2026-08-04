############################################
# GitHub Actions OIDC Identity Provider
############################################

data "tls_certificate" "github_actions" {
  count = var.create_github_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# AWS accounts allow only one OIDC provider per issuer URL. If a provider for
# token.actions.githubusercontent.com already exists (created manually, by
# another stack, or left over from a prior partial apply), creating it again
# here fails apply with "409 EntityAlreadyExists". Set
# create_github_oidc_provider = false to instead look it up via data source.
resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions[0].certificates[0].sha1_fingerprint]

  tags = local.common_tags
}

data "aws_iam_openid_connect_provider" "github_actions_existing" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : data.aws_iam_openid_connect_provider.github_actions_existing[0].arn
}

############################################
# CI/CD IAM Role (assumed via OIDC — no static AWS access keys)
############################################

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restrict to the configured GitHub org/repos, any branch/tag/environment.
    #
    # The wildcards after ${var.github_org} and each repo name aren't just
    # for the trailing ref/branch -- GitHub's actual sub claim embeds
    # immutable numeric org/repo IDs directly in the name segments, e.g.
    # "repo:final-project-2026-devops@308724323/sports-store-order-service@1311892377:ref:refs/heads/main"
    # (confirmed via CloudTrail on a real denied AssumeRoleWithWebIdentity
    # call), not the plain "repo:org/repo:ref:..." format most docs/examples
    # show. A pattern with the wildcard only at the end doesn't match that
    # -- it has to also cover the "@<id>" suffix on both the org and the
    # repo segments.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for repo in var.github_allowed_repositories : "repo:${var.github_org}*/${repo}*:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project_name}-github-actions-cicd"
  description          = "Assumed by GitHub Actions workflows via OIDC to build/deploy CloudCart"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  max_session_duration = 3600

  tags = local.common_tags
}

############################################
# Least-privilege permissions: push images to the 7 ECR repos
############################################

data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = [for repo in aws_ecr_repository.this : repo.arn]
  }
}

resource "aws_iam_policy" "github_actions_ecr" {
  name   = "${var.project_name}-github-actions-ecr-policy"
  policy = data.aws_iam_policy_document.github_actions_ecr.json
  tags   = local.common_tags
}

############################################
# Least-privilege permissions: deploy the frontend build to S3 + invalidate
# the CloudFront distribution cache
############################################

data "aws_iam_policy_document" "github_actions_frontend_deploy" {
  statement {
    sid    = "S3FrontendDeploy"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.frontend.arn,
      "${aws_s3_bucket.frontend.arn}/*",
    ]
  }

  statement {
    sid    = "CloudFrontInvalidation"
    effect = "Allow"
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
      "cloudfront:ListInvalidations",
    ]
    resources = [aws_cloudfront_distribution.frontend.arn]
  }
}

resource "aws_iam_policy" "github_actions_frontend_deploy" {
  name   = "${var.project_name}-github-actions-frontend-policy"
  policy = data.aws_iam_policy_document.github_actions_frontend_deploy.json
  tags   = local.common_tags
}

############################################
# Least-privilege permissions: describe the EKS cluster so pipelines can
# `aws eks update-kubeconfig` and deploy manifests (cluster access itself is
# granted via the access_entries block in eks.tf).
############################################

data "aws_iam_policy_document" "github_actions_eks_describe" {
  statement {
    sid       = "EKSDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_policy" "github_actions_eks_describe" {
  name   = "${var.project_name}-github-actions-eks-policy"
  policy = data.aws_iam_policy_document.github_actions_eks_describe.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_ecr.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_frontend_deploy" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_frontend_deploy.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_eks_describe" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_eks_describe.arn
}
