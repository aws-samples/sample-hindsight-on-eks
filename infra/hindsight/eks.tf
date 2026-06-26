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

  # EKS Auto Mode compute. Built in main.tf as local.cluster_compute_config:
  # a populated object in Auto Mode (general-purpose + system node pools, both
  # scale-from-zero so "system" is free while idle), or an EMPTY map in Fargate
  # mode so the module omits the compute_config block entirely. EKS requires
  # computeConfig, kubernetesNetworkConfig, and blockStorage to be ALL enabled or
  # ALL disabled; the module only renders the network/storage Auto Mode blocks
  # when compute_config.enabled is true, so passing {enabled=false} here would
  # render computeConfig alone and fail with "ensure that all required configs
  # ... are all either fully enabled or fully disabled".
  # NOTE: field is `cluster_compute_config` on the v20 module line (loosely typed).
  cluster_compute_config = local.cluster_compute_config

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
