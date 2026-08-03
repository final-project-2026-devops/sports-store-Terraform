# CloudCart — Project Status Report

**Author:** Eli (infrastructure)
**Date:** 2026-08-03
**Repo covered directly:** `sports-store-Terraform` (Terraform / AWS infra)

> Scope note: this report is authoritative for the infrastructure repo, which is
> what I've been working in. Status for the other 9 repos (frontend, gateway,
> 5 services, `sports-store-local`, `sports-store-deployments`) is based on
> what infra implies is needed next, not direct inspection — Michael's audit
> across all repos is the source of truth for those.

---

## 1. Milestone status vs. the project brief

| # | Milestone | Status |
|---|---|---|
| 1 | Docker Compose (optional) | Not verified from infra side |
| 2 | Local k8s (optional) | Not verified from infra side |
| 3 | Helm chart | Not verified from infra side |
| **4** | **Terraform infra** | **~90% done — see detail below** |
| 5 | Deploy app to cloud | Not started |
| 6 | CI (GitHub Actions) | Partial — OIDC/IAM role exists in infra repo; app-repo workflows not verified |
| 7 | GitOps (Argo CD) | Not started |
| 8 | Observability | Not started |
| — | Required extension | Candidate identified, not formally declared |

### Milestone 4 detail — Terraform infrastructure

**Done and verified directly against AWS:**
- VPC (`terraform-aws-modules/vpc/aws`): public/private subnets, single NAT gateway, S3 gateway endpoint.
- EKS cluster `cloudcart-production` (us-east-1, account `977237815280`), `ACTIVE`.
- Managed node group `ACTIVE` on `t3.small`, 2/2 healthy instances (see incident writeup below).
- Core add-ons `vpc-cni`, `coredns`, `kube-proxy` — confirmed `ACTIVE`.
- 7 ECR repositories (5 services + frontend + gateway).
- IAM: cluster role, node role, per-service IRSA roles (note: this infra provisions **DynamoDB** per service, not MongoDB as the brief assumes — confirm with the team whether this is an intentional architecture swap and document it as such).
- Terraform Cloud workspace connected (`final-project-2026-devops` org), remote state.

**Not yet applied (known, not forgotten — blocks milestone 5):**
- `aws_eks_addon` for the EBS CSI driver — IRSA role exists, addon itself not applied.
- AWS Load Balancer Controller Helm release + service account — IRSA role exists, workload not applied.

**Added beyond the original brief:**
- AWS Budget: $150/month, alerts at 50%/80%/100% actual + 100% forecasted spend, to all 4 team emails. Candidate for the required "extension" (cost dashboard).
- Team AWS access (IAM users) — see section 3.

---

## 2. EKS node group incident — diagnosis and fix

**Symptom:** managed node group stuck 24+ minutes in "Still creating...", Terraform plan showed a forced replace (`cannot_update`).

**Root cause (found by working down the stack — Terraform diff → EKS API → ASG activity history):**
`node_instance_types` had been changed from `t3.micro` to `t3.medium` to fix a real pod-density problem (`t3.micro` only supports 4 pods/node — not enough room for `aws-node` + `kube-proxy` + `coredns` + `ebs-csi-driver` + the LB controller). But this AWS account is restricted to Free Tier-eligible instance types only, and `t3.medium` doesn't qualify — every EC2 launch attempt from the new node group's ASG failed with `InvalidParameterCombination`, so it never got a single instance running.

**Fix:** switched to `t3.small` — still Free Tier-eligible, and supports 11 pods/node (enough headroom). Applied, verified `ACTIVE` with 2 healthy nodes. Also cleaned up an orphaned "deposed" node group object left over from the earlier failed replacement.

---

## 3. Team AWS access (Michael, Yotam, Amir)

IAM users created for all three, console + CLI (access key) access. Access level evolved based on actual blockers hit in practice:

1. Started at `PowerUserAccess` + a deny-overlay blocking creation of new billable resources.
2. Moved to `AdministratorAccess` (full access including IAM) + a deny-overlay blocking destructive actions (delete/terminate/remove) across most services, after the team needed broader access (e.g. `iam:ListUsers` was being denied under `PowerUserAccess`, which excludes all `iam:*` by design).
3. Excluded S3 and DynamoDB entirely from the destructive-action block — full CRUD including delete on the frontend bucket and app data tables, since that's expected day-to-day work.
4. Upgraded EKS cluster access from `AmazonEKSEditPolicy` to `AmazonEKSClusterAdminPolicy` — full `kubectl` access.
5. Dropped an MFA-required-for-everything rule after confirming (via a real CLI failure from Yotam) that static access keys never carry MFA context by AWS design — enforcing it meant every CLI call needed a manual `sts:GetSessionToken` + MFA-code round trip first. Traded strict enforcement for usability, deliberately — MFA is still set up per-account for console login, just not a precondition for every action.

One real bug hit and fixed along the way: an early version of the guardrail policy used `"*:Delete*"`-style wildcards, which IAM rejects (wildcards aren't allowed in the service/vendor prefix, only in the action-name suffix). Rewrote as an enumerated per-service list, generated via Terraform locals.

**Current state, verified live via `iam simulate-principal-policy`:** all three users have `AdministratorAccess` minus delete/terminate/remove on most services (S3/DynamoDB excluded from even that), plus EKS cluster-admin.

---

## 4. GitHub — source of truth

All infra changes are committed and pushed to `main` on `sports-store-Terraform`:

| Commit | Description |
|---|---|
| `a62c21a` | Fix node instance type (t3.medium → t3.small) + initial student IAM access + budget |
| `bd6fa52` | Full EKS cluster-admin + unrestricted S3/DynamoDB access for the team |
| `12387fb` | Dropped the MFA-enforcement guardrail |

**Flag for the team:** this repo does not yet have branch protection / PR-required set up on `main` — all pushes so far (including before I touched it) have been direct. The brief requires this on every repo. Worth fixing before demo.

---

## 5. Open items / known gaps

- [ ] Apply the deferred EBS CSI driver addon and AWS Load Balancer Controller (blocks milestone 5).
- [ ] Branch protection + PR-required on `sports-store-Terraform` (and presumably the other 9 repos — needs checking).
- [ ] CI/CD IAM role (`cloudcart-github-actions-cicd`) currently has `AmazonEKSClusterAdminPolicy` on the cluster — worth narrowing once Argo CD (milestone 7) takes over deploys, since the brief's design has only a scoped GitOps identity touching the cluster.
- [ ] Frontend S3 bucket + CloudFront exist but are empty — no build has been pushed yet, and no wiring exists yet between the (not-yet-created) ALB and CloudFront/the frontend's API base URL.
- [ ] Confirm/document the MongoDB → DynamoDB architecture swap explicitly, since the brief assumes MongoDB throughout (Bitnami Helm chart, EBS-backed PVC).
- [ ] Decide and formally declare the "required extension" — AWS Budgets is a strong, already-implemented candidate.
