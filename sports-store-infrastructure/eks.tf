############################################
# ALB Security Group (attached to ALBs provisioned by the AWS Load Balancer
# Controller via the alb.ingress.kubernetes.io/security-groups annotation)
############################################

resource "aws_security_group" "alb" {
  name        = "${local.cluster_name}-alb-sg"
  description = "Security group attached to ALBs provisioned by the AWS Load Balancer Controller"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from internet"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-alb-sg"
  })
}

############################################
# ALB in front of the EKS cluster (CloudFront's /api/* origin)
#
# Created directly by Terraform, not dynamically via a Kubernetes Ingress --
# this keeps its DNS name known immediately after apply, so CloudFront (in
# frontend_s3_cloudfront.tf) can use it as an origin without waiting on
# Michael's gateway/Ingress to exist first. The target group starts out
# with 0 healthy targets until it's bound to a real Service.
#
# To actually receive traffic: bind this target group to the gateway's
# Kubernetes Service via a TargetGroupBinding custom resource (provided by
# the AWS Load Balancer Controller, already installed below), e.g.:
#
#   apiVersion: elbv2.k8s.aws/v1beta1
#   kind: TargetGroupBinding
#   metadata:
#     name: gateway
#     namespace: sports-store
#   spec:
#     serviceRef:
#       name: gateway
#       port: 80
#     targetGroupARN: <alb_target_group_arn output>
#     targetType: ip
############################################

resource "aws_lb" "main" {
  name               = "${local.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-alb"
  })
}

resource "aws_lb_target_group" "gateway" {
  name        = "${local.cluster_name}-gateway-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

############################################
# EKS Cluster
############################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.eks_public_access_enabled
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Explicit (in addition to the implicit dependency via vpc_id/subnet_ids)
  # so the VPC and its route tables/NAT gateways are fully settled before
  # the cluster/node group are created, and fully torn down only after them
  # on destroy.
  depends_on = [module.vpc]

  enable_irsa = true

  # API_AND_CONFIG_MAP keeps the legacy aws-auth ConfigMap working while
  # allowing cluster access to also be managed declaratively via
  # access_entries below (e.g. for the GitHub Actions CI/CD role).
  authentication_mode = "API_AND_CONFIG_MAP"

  # false: AWS itself auto-creates a cluster-creator access entry for the
  # IAM principal that provisions the cluster. Leaving this true makes the
  # module also try to create that same entry, which fails apply with an
  # access-entry-already-exists conflict.
  enable_cluster_creator_admin_permissions = false

  # Only the managed EKS add-ons that don't require an IRSA role are created
  # inline. The EBS CSI driver is created as a standalone aws_eks_addon
  # resource below to avoid a dependency cycle (its service account role
  # needs the cluster's OIDC provider, which only exists once the cluster
  # this argument belongs to has already been created).
  cluster_addons = {
    vpc-cni = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    disk_size      = var.node_group_disk_size
    instance_types = var.node_instance_types

    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  eks_managed_node_groups = {
    default = {
      name = "${local.cluster_name}-default"

      # Explicit, non-prefixed IAM role name: the module's default
      # (`"${name}-eks-node-group-"` as a name_prefix) exceeds AWS's 38-char
      # name_prefix limit once cluster_name/environment get long enough.
      iam_role_use_name_prefix = false
      iam_role_name            = "${local.cluster_name}-default-role"

      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      subnet_ids = module.vpc.private_subnets

      labels = {
        role = "default"
      }

      tags = local.common_tags
    }
  }

  # Allow inbound traffic from the AWS Load Balancer Controller (ALB/NLB
  # target groups reach pods directly in IP target-type mode) on the
  # ephemeral port range used by container health checks and services.
  node_security_group_additional_rules = {
    ingress_alb_to_nodes = {
      description              = "Ingress from ALB security group to node ephemeral ports"
      protocol                 = "tcp"
      from_port                = 1025
      to_port                  = 65535
      type                     = "ingress"
      source_security_group_id = aws_security_group.alb.id
    }
  }

  # Grant the GitHub Actions CI/CD role cluster-admin via an EKS access
  # entry so pipelines can `kubectl apply` deployments without a static
  # aws-auth ConfigMap edit.
  #
  # devops-admin also needs an explicit entry: it's the identity Terraform
  # Cloud's remote runs authenticate as (workspace-level AWS_ACCESS_KEY_ID),
  # and it is not the cluster's original creator-admin principal, so without
  # this it has no cluster access at all. That gap is what caused
  # kubernetes_service_account / helm_release applies to fail with
  # "Unauthorized" even after fixing the kubernetes/helm provider auth to
  # use the exec plugin.
  access_entries = {
    github_actions = {
      principal_arn = aws_iam_role.github_actions.arn

      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }

    devops_admin = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/devops-admin"

      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = local.common_tags
}

############################################
# EBS CSI Driver add-on (standalone to avoid an IRSA <-> addon cycle)
############################################

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${local.cluster_name}-ebs-csi-irsa"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags

  depends_on = [module.eks]
}

data "aws_eks_addon_version" "ebs_csi_driver" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi_driver.version
  service_account_role_arn    = module.ebs_csi_irsa_role.iam_role_arn
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  tags = local.common_tags

  depends_on = [module.eks]
}

############################################
# AWS Load Balancer Controller (IRSA role + Helm release)
############################################

module "lb_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${local.cluster_name}-lb-controller-irsa"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.common_tags

  depends_on = [module.eks]
}

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = module.lb_controller_irsa_role.iam_role_arn
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.lb_controller_chart_version

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
  }

  depends_on = [
    module.eks,
    kubernetes_service_account.aws_load_balancer_controller,
    aws_eks_addon.ebs_csi_driver,
  ]
}
