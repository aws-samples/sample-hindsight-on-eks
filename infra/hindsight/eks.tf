module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "${var.project_name}-cluster"
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow public API access (for Terraform and kubectl from your machine)
  cluster_endpoint_public_access = true

  # Ensure the Terraform caller gets cluster admin access
  enable_cluster_creator_admin_permissions = true

  # Fargate profiles — only when compute_mode = "fargate". In Auto Mode, managed
  # NodePools handle all pods, so no Fargate profiles are created.
  fargate_profiles = local.auto_mode ? {} : {
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

  # EKS Auto Mode compute — only when compute_mode = "auto". Uses both built-in
  # node pools: "system" (taints nodes for critical add-ons) and "general-purpose"
  # (workload pods). Both scale from zero, so "system" costs nothing while idle.
  # NOTE: field is `cluster_compute_config` on the v20 module line (loosely typed).
  cluster_compute_config = local.auto_mode ? {
    enabled    = true
    node_pools = ["general-purpose", "system"]
    } : {
    enabled    = false
    node_pools = []
  }

  # Required for AWS LB Controller IRSA
  enable_irsa = true

  # CoreDNS Fargate patch — only in Fargate mode. By default CoreDNS carries an
  # annotation that prevents scheduling on Fargate; this patch sets computeType.
  # In Auto Mode, CoreDNS runs on managed nodes and needs no patch.
  cluster_addons = local.auto_mode ? {} : {
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
