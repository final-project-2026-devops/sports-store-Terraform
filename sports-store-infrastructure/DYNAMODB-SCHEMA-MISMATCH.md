# DynamoDB schema mismatch — app code vs `dynamodb.tf`

Found 2026-08-03/04 while fixing the table-name/IRSA bugs across all 5 backend services
(auth/cart/catalog/order/payment). The bugs are fixed and all 5 services now pass their test
suites locally (62/62), reading the table name from `DYNAMODB_TABLE_NAME` instead of hardcoding
it. But every service's code was written against the 6-table/GSI schema documented in
`ROADMAP.md` and `LAB-ELI.md`, and `dynamodb.tf` currently provisions a different, simpler
shape: one table per service, single hash key, **no GSIs at all**. Fixing the table name alone
is not enough — every service will throw a `ValidationException` on its first real DynamoDB
call because the key it queries by doesn't match the table's actual key schema.

## The mismatch, table by table

| Service | Code expects (verified against the actual route files) | `dynamodb.tf` currently provisions |
|---|---|---|
| auth-service | table with hash key `user_id` + **GSI `email-index`** (PK `email`) — used for login-by-email and register uniqueness check, `routes/auth.py` lines ~18-46 | `auth-service-table`, hash key `user_id`, **no GSI** |
| catalog-service | **two tables**: `products_table` (hash key `product_id`, GSI `slug-index`) and `variants_table` (hash key `sku`, GSI `product-index`) — `routes/products.py`, `routes/internal.py` | **one table**, `catalog-service-table`, hash key `item_id`, no GSI |
| cart-service | table with hash key `user_id` (get_item/put_item/delete_item all keyed by `user_id`) — `routes/cart.py` | `cart-service-table`, hash key `cart_id` |
| order-service | table with hash key `order_number` + **GSI `user-index`** (PK `user_id`, SK `created_at`) — used for order-history-by-user, `routes/orders.py` line ~53 | `order-service-table`, hash key `order_id`, no GSI |
| payment-service | table with hash key `idempotency_key` — `routes/payments.py` | `payment-service-table`, hash key `payment_id` |

## What needs to change in `dynamodb.tf`

1. **auth-service, cart-service, order-service, payment-service**: rename each table's hash key
   to match the code (`user_id`, `user_id`, `order_number`, `idempotency_key` respectively —
   note cart and auth both use `user_id`, that's correct, they're different tables).
2. **auth-service**: add GSI `email-index`, PK `email`.
3. **order-service**: add GSI `user-index`, PK `user_id`, SK `created_at`.
4. **catalog-service**: split into two tables —
   - `catalog-service-table` (or similar), hash key `product_id`, GSI `slug-index` (PK `slug`)
   - a new `catalog-service-variants-table` (or similar), hash key `sku`, GSI `product-index`
     (PK `product_id`)
5. Update `local.dynamodb_tables` and the per-service IRSA policy's `Resource` list to include
   `/index/*` on each table that gets a GSI (already present in the current policy shape, just
   needs to apply to the new/changed tables).
6. Once table/GSI names are final, publish them so the 5 services' `values-aws.yaml` entries
   (`DYNAMODB_TABLE_NAME`, and a new `DYNAMODB_VARIANTS_TABLE_NAME` for catalog-service) match
   exactly — catalog-service's `database.py` already reads both env vars, defaulting to
   `catalog-service-table` / `Variants` if unset.

## Why fix Terraform instead of rewriting the app code

The GSI-based design is the one that's actually documented and reasoned through (`LAB-ELI.md`
explains why `Variants` needs to be its own table — DynamoDB can't conditionally update one
element of a nested List, which is why the atomic stock-decrement needs a real table with its
own hash key). Rewriting the 5 services to drop GSIs would be a real correctness/performance
regression, not a simplification — e.g. auth login-by-email would become a full table `Scan`
instead of an indexed `Query`.

## Verification once fixed

Each service's test suite already mocks the correct calls (`IndexName="email-index"` etc.) — so
once the real tables/GSIs match, running each service against DynamoDB Local or the real cluster
should just work without further code changes. No app-code changes needed beyond what's already
merged.
