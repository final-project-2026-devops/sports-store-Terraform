############################################
# DynamoDB Tables (one per microservice, plus a second table for
# catalog-service's product variants/stock)
#
# Schema (hash/range keys + GSIs) comes from what the app code actually
# queries by -- see DYNAMODB-SCHEMA-MISMATCH.md for the per-service
# verification against each service's route files. The table shape this
# file provisioned before did not match: wrong hash keys on 4 of the 5
# tables, no GSIs at all, and catalog-service needs a second table (a
# nested List can't be conditionally/atomically updated per-element in
# DynamoDB, which is why variants/stock need their own table+hash key).
############################################

locals {
  dynamodb_tables = {
    auth = {
      table_name = "auth-service-table"
      hash_key   = "user_id"
      range_key  = null
      # Login-by-email and the register uniqueness check query by email,
      # not user_id.
      gsis = [
        { name = "email-index", hash_key = "email", range_key = null }
      ]
    }
    cart = {
      table_name = "cart-service-table"
      hash_key   = "user_id"
      range_key  = null
      gsis       = []
    }
    catalog = {
      table_name = "catalog-service-table"
      hash_key   = "product_id"
      range_key  = null
      # Product-detail-by-slug lookups query by slug, not product_id.
      gsis = [
        { name = "slug-index", hash_key = "slug", range_key = null }
      ]
    }
    order = {
      table_name = "order-service-table"
      hash_key   = "order_number"
      range_key  = null
      # Order-history-by-user, sorted by creation time.
      gsis = [
        { name = "user-index", hash_key = "user_id", range_key = "created_at" }
      ]
    }
    payment = {
      table_name = "payment-service-table"
      hash_key   = "idempotency_key"
      range_key  = null
      gsis       = []
    }
  }

  catalog_variants_table = {
    table_name = "catalog-service-variants-table"
    hash_key   = "sku"
    range_key  = null
    # Variant lookups by parent product, e.g. "all variants of this product".
    gsis = [
      { name = "product-index", hash_key = "product_id", range_key = null }
    ]
  }

  # DynamoDB rejects duplicate `attribute` definitions on the same table, so
  # each table's hash/range key and every GSI's hash/range key are
  # deduplicated into a single attribute list per table.
  dynamodb_table_attribute_names = {
    for k, v in local.dynamodb_tables : k => distinct(concat(
      [v.hash_key],
      v.range_key != null ? [v.range_key] : [],
      [for g in v.gsis : g.hash_key],
      [for g in v.gsis : g.range_key if g.range_key != null],
    ))
  }

  catalog_variants_attribute_names = distinct(concat(
    [local.catalog_variants_table.hash_key],
    local.catalog_variants_table.range_key != null ? [local.catalog_variants_table.range_key] : [],
    [for g in local.catalog_variants_table.gsis : g.hash_key],
    [for g in local.catalog_variants_table.gsis : g.range_key if g.range_key != null],
  ))
}

resource "aws_dynamodb_table" "this" {
  for_each = local.dynamodb_tables

  name         = each.value.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.hash_key
  range_key    = each.value.range_key

  dynamic "attribute" {
    for_each = local.dynamodb_table_attribute_names[each.key]
    content {
      name = attribute.value
      type = "S"
    }
  }

  dynamic "global_secondary_index" {
    for_each = { for g in each.value.gsis : g.name => g }
    content {
      name            = global_secondary_index.value.name
      hash_key        = global_secondary_index.value.hash_key
      range_key       = global_secondary_index.value.range_key
      projection_type = "ALL"
    }
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

resource "aws_dynamodb_table" "catalog_variants" {
  name         = local.catalog_variants_table.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = local.catalog_variants_table.hash_key

  dynamic "attribute" {
    for_each = local.catalog_variants_attribute_names
    content {
      name = attribute.value
      type = "S"
    }
  }

  dynamic "global_secondary_index" {
    for_each = { for g in local.catalog_variants_table.gsis : g.name => g }
    content {
      name            = global_secondary_index.value.name
      hash_key        = global_secondary_index.value.hash_key
      range_key       = global_secondary_index.value.range_key
      projection_type = "ALL"
    }
  }

  point_in_time_recovery {
    enabled = var.enable_dynamodb_pitr
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name    = local.catalog_variants_table.table_name
    Service = "catalog-service"
  })
}

############################################
# Per-service least-privilege IAM policies + IRSA roles
#
# Each microservice pod assumes its own IRSA role (bound to a Kubernetes
# ServiceAccount named "<service>-service-sa" in var.k8s_namespace) that can
# only read/write the table(s) it owns. catalog-service is the only service
# with two tables.
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
        Resource = concat(
          [
            aws_dynamodb_table.this[each.key].arn,
            "${aws_dynamodb_table.this[each.key].arn}/index/*",
          ],
          each.key == "catalog" ? [
            aws_dynamodb_table.catalog_variants.arn,
            "${aws_dynamodb_table.catalog_variants.arn}/index/*",
          ] : []
        )
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
