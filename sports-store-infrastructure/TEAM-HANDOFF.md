# CloudCart Infrastructure — Team Handoff

Generated from `terraform output -json` against the live `sports-store-infrastructure`
state (account `977237815280`, region `us-east-1`) on 2026-08-04. Read only your own
section unless you need the shared context below.

**Not everything below is finished or working yet.** Two blockers affect multiple people
and are called out explicitly where relevant — don't assume something works just because
a resource exists.

---

## Global Info

| | |
|---|---|
| AWS account ID | `977237815280` |
| Region | `us-east-1` |
| EKS cluster | `cloudcart-production` |
| Frontend URL (stable) | `https://d1oz5oxgd4iyf6.cloudfront.net` |
| Backend/API URL | **Not available yet** — see blocker below |

**Console access / passwords:** deliberately *not* included in this file. Temporary
passwords are per-person secrets — send each one individually to that person over a
private channel, never in a shared doc. If you don't have yours, ask directly.

**Blocker #1 — AWS Load Balancer Controller isn't deployed.** `kubernetes_service_account.aws_load_balancer_controller`
and its `helm_release` have never successfully applied (a token-auth bug, now fixed in
code but not yet re-applied). Until that apply runs, there is **no ALB, no Ingress
routing, and no stable API endpoint** — this blocks Amir (can't expose services) and
Yotam (nothing to point the frontend at).

**Blocker #2 — the GitHub Actions IAM role's trust policy is still a placeholder.**
`var.github_org` is set to its literal default, `"your-github-org"`, not the real org
(`final-project-2026-devops`). The role currently cannot be assumed by any real GitHub
Actions workflow. This blocks Michael. Fix is a one-line `terraform.tfvars` change +
apply (infra-side, not something to work around in a workflow file).

---

## Amir
**Scope:** building and deploying the backend services to EKS via the ECR repos.

### What you need to know
- EKS cluster: `cloudcart-production`
  - Endpoint: `https://9B2EF2B60E825586341D4C2A3C819840.gr7.us-east-1.eks.amazonaws.com`
  - Get kubectl access: `aws eks update-kubeconfig --name cloudcart-production --region us-east-1` (your IAM user already has cluster-admin via an EKS access entry — confirmed live, no setup needed there).
- ECR repos (backend + gateway):
  | Service | Repo URL |
  |---|---|
  | auth | `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-auth-service` |
  | cart | `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-cart-service` |
  | catalog | `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-catalog-service` |
  | order | `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-order-service` |
  | payment | `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-payment-service` |
  | gateway | `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-gateway` |
- Per-service DynamoDB table + IRSA role (annotate each service's Kubernetes ServiceAccount with the matching role ARN):
  | Service | Table | IRSA role ARN |
  |---|---|---|
  | auth | `auth-service-table` | `arn:aws:iam::977237815280:role/cloudcart-production-auth-service-irsa` |
  | cart | `cart-service-table` | `arn:aws:iam::977237815280:role/cloudcart-production-cart-service-irsa` |
  | catalog | `catalog-service-table` | `arn:aws:iam::977237815280:role/cloudcart-production-catalog-service-irsa` |
  | order | `order-service-table` | `arn:aws:iam::977237815280:role/cloudcart-production-order-service-irsa` |
  | payment | `payment-service-table` | `arn:aws:iam::977237815280:role/cloudcart-production-payment-service-irsa` |
- **Namespace caveat:** the IRSA roles' trust policies are currently bound to the
  `cloudcart` namespace (`system:serviceaccount:cloudcart:<service>-service-sa`) — that's
  what's *live* right now, even though `var.k8s_namespace` is meant to end up as
  `sports-store`. That change is written but not yet applied. **Deploy into the `cloudcart`
  namespace for now**; if/when the namespace fix is applied, these trust policies (and
  your manifests) will need to move to `sports-store` together, not independently.

### What you need to do
- [ ] Confirm the `cloudcart` vs `sports-store` namespace question with infra before deploying (see caveat above) — don't guess.
- [ ] Build and push each service's image to its ECR repo above.
- [ ] Create a Kubernetes ServiceAccount per service, annotated `eks.amazonaws.com/role-arn` with the matching IRSA role ARN, in the agreed namespace.
- [ ] Point each service's DynamoDB client at its table name above (not a hardcoded table name in code).

### Dependencies / blockers
- Blocked on **Blocker #1** (LB Controller) for any Ingress/ALB-based routing to your services — you can still deploy pods/services and validate DynamoDB access before that lands, but external traffic won't reach them yet.
- Waiting on infra to confirm/apply the `cloudcart` → `sports-store` namespace decision.

---

## Michael
**Scope:** setting up the GitHub Actions CI/CD pipeline that pushes images to ECR using the OIDC role.

### What you need to know
- OIDC provider: `arn:aws:iam::977237815280:oidc-provider/token.actions.githubusercontent.com`
- CI/CD role to assume: `arn:aws:iam::977237815280:role/cloudcart-github-actions-cicd`
- Repos currently trusted in the role's `sub` condition (any branch/tag/environment): `sports-store-infrastructure`, `sports-store-frontend`, `sports-store-gateway`, `sports-store-auth-service`, `sports-store-catalog-service`, `sports-store-cart-service`, `sports-store-order-service`, `sports-store-payment-service`. (Not included: `sports-store-k8s`, `sports-store-local`, `sports-store-deployments` — add them to `var.github_allowed_repositories` if any of those need to push images too.)
- Role permissions: ECR push/pull (`GetAuthorizationToken`, layer upload, `PutImage`, etc.) scoped to the 7 repo ARNs, plus S3/CloudFront deploy permissions for the frontend and `eks:DescribeCluster`/`ListClusters`. It does **not** currently have permissions to deploy into the cluster itself (no RBAC/access entry for this role beyond describe) — flag to infra if your pipeline needs to `kubectl apply`.
- Full ECR URL map is in Amir's section above (6 backend/gateway repos) plus `sports-store-frontend`: `977237815280.dkr.ecr.us-east-1.amazonaws.com/sports-store-frontend`.

### What you need to do
- [ ] **Don't build against this role yet** — see the blocker below, it will fail every `AssumeRoleWithWebIdentity` call until infra fixes it.
- [ ] Once fixed, in each workflow use `aws-actions/configure-aws-credentials` with `role-to-assume: arn:aws:iam::977237815280:role/cloudcart-github-actions-cicd` and no static AWS keys.
- [ ] Confirm with infra whether `sports-store-k8s`/`sports-store-local`/`sports-store-deployments` need to be added to the trusted-repo list for your pipeline design.

### Dependencies / blockers
- **Blocker #2** (this doc's top section): the role's trust policy currently says `repo:your-github-org/...` — a literal unfixed placeholder, not `final-project-2026-devops`. Nothing can assume this role until `github_org` is corrected in `terraform.tfvars` and re-applied. This is an infra fix, not a workflow-file bug — don't spend time debugging your YAML if you hit an OIDC trust error.

---

## Yotam
**Scope:** deploying the frontend to the S3 bucket behind CloudFront.

### What you need to know
- S3 bucket: `cloudcart-frontend-production-977237815280` (private; only readable via CloudFront, not directly).
- CloudFront distribution: `d1oz5oxgd4iyf6.cloudfront.net` (ID `E7O4FT0I3NRYO`, needed for cache invalidations).
- No custom domain is configured (`frontend_domain_aliases`/`acm_certificate_arn` are both unset) — the CloudFront default domain above *is* the real, stable frontend URL for now.
- SPA routing is already handled: 403/404 on the private bucket falls back to `/index.html` (200), so client-side routing works without extra config.

### What you need to do
- [ ] Build the frontend and sync it to the bucket: `aws s3 sync ./dist s3://cloudcart-frontend-production-977237815280 --delete`
- [ ] Invalidate the cache after each deploy: `aws cloudfront create-invalidation --distribution-id E7O4FT0I3NRYO --paths "/*"`
- [ ] **Make the API base URL configurable at build/runtime (env var), not hardcoded** — there isn't a real value to put in yet (see blocker below), and you don't want a full rebuild just to point at a new endpoint once one exists.

### Dependencies / blockers
- **Blocker #1** (this doc's top section): there is no `/api/*` routing on this CloudFront distribution (it's S3-only, single origin, checked directly in `frontend_s3_cloudfront.tf`), and no ALB/Ingress exists yet either. There is currently **no real API URL to give you**. Get one from infra once the LB Controller apply lands — don't invent or hardcode a placeholder in the meantime.
