module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project_name}-cluster"
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow public API access (for Terraform and kubectl from your machine)
  cluster_endpoint_public_access = true

  # Ensure the Terraform caller gets cluster admin access
  enable_cluster_creator_admin_permissions = true

  # Fargate profiles
  fargate_profiles = {
    hindsight = {
      selectors = [
        { namespace = "hindsight" }
      ]
      subnet_ids = module.vpc.private_subnets
    }
    kube_system = {
      selectors = [
        { namespace = "kube-system" }
      ]
      subnet_ids = module.vpc.private_subnets
    }
  }

  # Required for AWS LB Controller IRSA
  enable_irsa = true

  # Patch CoreDNS for Fargate-only clusters:
  # By default CoreDNS has an annotation that prevents scheduling on Fargate.
  # The EKS module's cluster_addons configuration handles this automatically.
  cluster_addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
  }

  tags = local.tags
}

# Create the hindsight namespace (Fargate profiles match on namespace)
resource "kubernetes_namespace" "hindsight" {
  metadata {
    name = "hindsight"
  }

  depends_on = [module.eks]
}
