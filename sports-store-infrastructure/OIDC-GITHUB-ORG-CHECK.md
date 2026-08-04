# GitHub Actions OIDC role rejects every service — likely `github_org` variable

Found 2026-08-04 wiring the (already-existing) `cloudcart-github-actions-cicd` role ARN into
`sports-store-auth-service`'s CI. Lint/test/build passed, PR merged, but the real ECR push step
failed:

```
##[error]Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

## Root cause hypothesis

`iam_oidc_github.tf`'s trust policy is built from two variables:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [for repo in var.github_allowed_repositories : "repo:${var.github_org}/${repo}:*"]
}
```

- `github_allowed_repositories` — checked, already correctly includes all 7 app repos
  (`sports-store-auth-service`, etc.) via its default in `variables.tf`.
- `github_org` — **defaults to the literal placeholder `"your-github-org"`** in `variables.tf`.
  The real value (`final-project-2026-devops`) has to come from `terraform.tfvars` or a
  Terraform Cloud workspace variable — both invisible from a local checkout (`.gitignore`s
  `*.tfvars`).

If `github_org` was never explicitly overridden, the trust policy is built against
`repo:your-github-org/sports-store-auth-service:*`, which will never match the real OIDC
token's `sub` claim (`repo:final-project-2026-devops/sports-store-auth-service:ref:refs/heads/main`)
— exactly the failure observed. This blocks the ECR push step on **every** service, not just
auth-service, since they all hit the same role/trust policy.

## Ask

Please confirm whether `github_org` is set correctly in the Terraform Cloud workspace (or
`terraform.tfvars`). If it's still the default, set it to `final-project-2026-devops` and
re-apply — this is the only change needed on the infra side; the CI workflows themselves are
already wired correctly (verified: `configure-aws-credentials` reaches AWS and gets a clean
`AccessDenied`-style rejection, not a network/config error on the GitHub Actions side).

## What's already been rolled out expecting this fix

The OIDC wiring (real role ARN, ECR login, build+push) has been added to all 5 backend
services' CI (`auth`/`cart`/`catalog`/`order`/`payment`-service), each on their
`fix/table-name-irsa-tests-ruff` branch/PR. Once `github_org` is confirmed correct, merging
those PRs (or re-running the workflow on `main` if already merged) should produce real images
in all 5 ECR repos with no further changes needed.
