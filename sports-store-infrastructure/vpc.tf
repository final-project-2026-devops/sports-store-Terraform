module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = local.azs

  # /20 subnets carved out of the /16 VPC CIDR: indexes 0-1 for public,
  # 2-3 for private, leaving room to grow into additional AZs/tiers later.
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + var.az_count)]

  enable_nat_gateway     = true
  single_nat_gateway     = true # 1 NAT Gateway shared across AZs for cost efficiency
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.common_tags
}

# S3 Gateway VPC Endpoint: keeps ECR image layer pulls (backed by S3) and
# other S3 traffic from private subnets off the NAT Gateway, reducing data
# processing costs.
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-s3-endpoint"
  })
}
