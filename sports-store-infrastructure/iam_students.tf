############################################
# Near-full access for student teammates (console + kubectl)
#
# Each teammate gets an IAM user with a temporary console password (reset
# required on first login). Group policy is AdministratorAccess (full
# access, including IAM) with a Deny overlay that (1) requires MFA for
# everything except self-enrolling an MFA device, and (2) blocks destructive
# actions (Delete/Terminate/Remove/Destroy/Purge/Revoke/Deregister) across
# services. NOTE: because these users also have IAM write access, the Deny
# overlay is a soft guardrail against accidents, not a hard boundary — a
# user could edit or detach this very policy. Trusted-teammate model, not a
# least-privilege one. Cluster access (kubectl) is granted separately via an
# EKS access entry per user.
############################################

locals {
  # Per-service destructive-verb action list for the guardrails Deny below.
  # IAM requires a literal service prefix (no wildcards there), so this is
  # generated rather than a single "*:Delete*"-style pattern.
  # s3 and dynamodb intentionally excluded — full CRUD (including delete) on
  # the frontend bucket and the app's data tables is expected day-to-day
  # work, not an edge case worth guarding against here.
  destructive_verbs = ["Delete", "Terminate", "Remove"]
  guardrail_services = [
    "ec2", "eks", "ecs", "ecr", "rds", "elasticache",
    "redshift", "docdb", "neptune", "iam", "elasticloadbalancing",
    "cloudfront", "route53", "acm", "autoscaling", "opensearch", "es",
    "kafka", "sagemaker", "globalaccelerator", "workspaces", "lambda",
    "efs", "fsx", "sns", "sqs", "kms", "secretsmanager", "ssm", "logs",
    "cloudwatch", "cloudformation", "apigateway", "states", "glue",
    "batch", "organizations",
  ]
  destructive_actions = flatten([
    for svc in local.guardrail_services : [
      for verb in local.destructive_verbs : "${svc}:${verb}*"
    ]
  ])
}

resource "aws_iam_group" "students" {
  name = "${var.project_name}-students"
}

resource "aws_iam_user" "students" {
  for_each = { for s in var.students : s.name => s }

  name = "${var.project_name}-${each.key}"

  tags = merge(local.common_tags, {
    Name  = each.key
    Email = each.value.email
  })
}

resource "aws_iam_user_login_profile" "students" {
  for_each = aws_iam_user.students

  user                    = each.value.name
  password_reset_required = true
}

resource "aws_iam_group_membership" "students" {
  name  = "${var.project_name}-students-membership"
  group = aws_iam_group.students.name
  users = [for u in aws_iam_user.students : u.name]
}

resource "aws_iam_group_policy_attachment" "students_admin_access" {
  group      = aws_iam_group.students.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

data "aws_iam_policy_document" "students_guardrails" {
  statement {
    sid    = "AllowSelfServiceMFAAndPasswordAlways"
    effect = "Allow"
    actions = [
      "iam:CreateVirtualMFADevice",
      "iam:EnableMFADevice",
      "iam:ResyncMFADevice",
      "iam:DeactivateMFADevice",
      "iam:DeleteVirtualMFADevice",
      "iam:ListMFADevices",
      "iam:ListVirtualMFADevices",
      "iam:GetUser",
      "iam:ChangePassword",
    ]
    resources = [
      "arn:aws:iam::*:mfa/$${aws:username}",
      "arn:aws:iam::*:user/$${aws:username}",
    ]
  }

  statement {
    sid    = "DenyEverythingElseWithoutMFA"
    effect = "Deny"
    not_actions = [
      "iam:CreateVirtualMFADevice",
      "iam:EnableMFADevice",
      "iam:ResyncMFADevice",
      "iam:ListMFADevices",
      "iam:ListVirtualMFADevices",
      "iam:GetUser",
      "iam:ChangePassword",
      "sts:GetSessionToken",
    ]
    resources = ["*"]

    condition {
      test     = "BoolIfExists"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["false"]
    }
  }

  # Blocks the common destructive-verb naming conventions across AWS
  # services. IAM rejects wildcards in the service/vendor prefix (only "*"
  # alone, or a literal service name, is valid there) — so this has to be
  # enumerated per service rather than "*:Delete*". Not exhaustive (AWS
  # naming isn't fully consistent — e.g. KMS uses ScheduleKeyDeletion, not
  # Delete*), and — see the file header — not unbypassable, since these
  # users also have IAM write access and could remove this statement
  # itself. Best-effort accident guard, not a security boundary.
  statement {
    sid    = "DenyDestructiveActions"
    effect = "Deny"
    actions = concat(
      local.destructive_actions,
      ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
    )
    resources = ["*"]
  }
}

resource "aws_iam_policy" "students_guardrails" {
  name        = "${var.project_name}-students-guardrails"
  description = "MFA enforcement + deny-destructive-actions overlay on top of AdministratorAccess for student accounts"
  policy      = data.aws_iam_policy_document.students_guardrails.json
  tags        = local.common_tags
}

resource "aws_iam_group_policy_attachment" "students_guardrails" {
  group      = aws_iam_group.students.name
  policy_arn = aws_iam_policy.students_guardrails.arn
}

############################################
# EKS cluster access (kubectl) — full cluster admin
############################################

resource "aws_eks_access_entry" "students" {
  for_each = aws_iam_user.students

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.arn
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "students_admin" {
  for_each = aws_iam_user.students

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.students]
}
