############################################
# DynamoDB Tables (one per microservice)
############################################

locals {
  dynamodb_tables = {
    auth = {
      table_name = "auth-service-table"
      hash_key   = "user_id"
    }
    catalog = {
      table_name = "catalog-service-table"
      hash_key   = "item_id"
    }
    cart = {
      table_name = "cart-service-table"
      hash_key   = "cart_id"
    }
    order = {
      table_name = "order-service-table"
      hash_key   = "order_id"
    }
    payment = {
      table_name = "payment-service-table"
      hash_key   = "payment_id"
    }
  }
}

resource "aws_dynamodb_table" "this" {
  for_each = local.dynamodb_tables

  name         = each.value.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.hash_key

  attribute {
    name = each.value.hash_key
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.enable_dynamodb_pitr
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name    = each.value.table_name
    Service = "${each.key}-service"
  })
}

############################################
# Per-service least-privilege IAM policies + IRSA roles
#
# Each microservice pod assumes its own IRSA role (bound to a Kubernetes
# ServiceAccount named "<service>-service-sa" in var.k8s_namespace) that can
# only read/write the single DynamoDB table it owns.
############################################

resource "aws_iam_policy" "dynamodb_service_access" {
  for_each = local.dynamodb_tables

  name        = "${local.cluster_name}-${each.key}-dynamodb-policy"
  description = "Least-privilege access to ${each.value.table_name} for the ${each.key} microservice"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBTableAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:ConditionCheckItem",
          "dynamodb:DescribeTable",
        ]
        Resource = [
          aws_dynamodb_table.this[each.key].arn,
          "${aws_dynamodb_table.this[each.key].arn}/index/*",
        ]
      }
    ]
  })

  tags = local.common_tags
}

module "dynamodb_service_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  for_each = local.dynamodb_tables

  role_name = "${local.cluster_name}-${each.key}-service-irsa"

  role_policy_arns = {
    dynamodb = aws_iam_policy.dynamodb_service_access[each.key].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.k8s_namespace}:${each.key}-service-sa"]
    }
  }

  tags = merge(local.common_tags, {
    Service = "${each.key}-service"
  })
}
