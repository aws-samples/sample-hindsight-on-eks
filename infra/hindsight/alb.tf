# IAM role for the AWS Load Balancer Controller (IRSA)
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix = "${var.project_name}-lb-ctrl-"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

# Deploy the AWS Load Balancer Controller via Helm
resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.4"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.lb_controller_irsa.iam_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  # High availability: chart default replicaCount is already 2; we set it
  # explicitly and add a PodDisruptionBudget (maxUnavailable=1, which the chart
  # only renders when replicaCount > 1). The PDB is the real lever: it keeps at
  # least one controller available during disruption (node drain, teardown) so
  # a leader keeps reconciling and ALB ingress finalizers are processed instead
  # of deadlocking. See null_resource.alb_drain below and docs/deployment.md.
  set {
    name  = "replicaCount"
    value = "2"
  }

  set {
    name  = "podDisruptionBudget.maxUnavailable"
    value = "1"
  }

  depends_on = [module.eks]
}

# Destroy-time drain: before the Load Balancer Controller is torn down, delete
# the ingresses it manages (both the chart-managed API ingress and the
# Terraform-managed Control Plane ingress) and wait for the shared ALB to be
# removed. Without this, `terraform destroy` can race the controller: Helm
# uninstall does not block on the ingress finalizer
# (group.ingress.k8s.aws/<group>), so the controller may be removed while an
# ingress is still Terminating, leaving the finalizer unprocessable and the
# ALB orphaned (a teardown deadlock).
#
# This resource depends_on the controller, the Hindsight Helm release, and both
# Control Plane ingress variants. Because Terraform destroys a resource BEFORE
# the things it depends on, this resource's destroy-time provisioner runs FIRST
# at teardown -- while the controller is still reconciling and able to process
# finalizers and delete the ALB.
resource "null_resource" "alb_drain" {
  # NOTE: these values are captured into triggers because destroy-time
  # provisioners may only reference `self`, not vars or other resources.
  # Because they are triggers, changing aws_region/aws_profile/project_name on
  # an EXISTING deployment replaces this resource, which runs the destroy-time
  # drain (deleting ingresses + the ALB) during the apply. Those values rarely
  # change on a live stack; if you must change them, expect ALB churn.
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.aws_region
    profile      = var.aws_profile
    namespace    = "hindsight"
    # The ALB name is k8s-<ingress group.name>-<hash>. The ingress group.name is
    # the literal "hindsight" (see hindsight.tf), NOT var.project_name, so match
    # on that to find the shared ALB regardless of project_name.
    alb_name_prefix = "k8s-hindsight"
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      KUBECONFIG_FILE="$(mktemp)"
      export KUBECONFIG="$KUBECONFIG_FILE"
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT

      REGION="${self.triggers.region}"
      PROFILE="${self.triggers.profile}"
      NS="${self.triggers.namespace}"
      ALB_PREFIX="${self.triggers.alb_name_prefix}"

      # Build an isolated kubeconfig using the same profile/region as the providers.
      if ! aws eks update-kubeconfig \
        --name "${self.triggers.cluster_name}" \
        --region "$REGION" \
        --profile "$PROFILE" >/dev/null 2>&1; then
        echo "alb_drain: cluster unreachable; assuming already destroyed, skipping."
        exit 0
      fi

      # Delete ONLY the chart-managed API ingress ("hindsight"). The Terraform-
      # managed Control Plane ingress ("hindsight-control-plane") is left for
      # Terraform to delete itself -- deleting it here makes Terraform's own delete
      # fail with "ingress ... not found". With the controller's IAM kept alive
      # (see depends_on below), the controller processes each ingress's
      # group.ingress.k8s.aws/<group> finalizer as it is deleted (here for the chart
      # ingress, by Terraform for the control-plane ingress) and removes the shared
      # ALB once the last group member is gone. --wait=false: we poll below.
      kubectl delete ingress hindsight -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true

      # Wait for the controller to actually process the chart ingress's finalizer
      # (object fully gone). This is the health check that the controller is doing
      # its job; if it is, it will likewise clean up the control-plane ingress that
      # Terraform deletes next, and tear down the ALB. The controller normally
      # clears a finalizer within a minute; allow ~5 as headroom.
      for i in $(seq 1 30); do
        if ! kubectl get ingress hindsight -n "$NS" >/dev/null 2>&1; then
          echo "alb_drain: chart ingress finalizer processed by controller."
          exit 0
        fi
        echo "alb_drain: waiting for controller to process chart ingress finalizer ($i/30)..."
        sleep 10
      done

      # Fallback safety valve: the controller did not process the finalizer in time
      # (e.g. it stopped reconciling). Clear the chart ingress finalizer directly so
      # the teardown does not deadlock. We do NOT remove the controller or its
      # webhooks (that blocks ingress mutation and creates phantom
      # TargetGroupBindings); clearing the finalizer while the controller is up is
      # the safe action.
      echo "alb_drain: controller did not converge; clearing chart ingress finalizer."
      kubectl patch ingress hindsight -n "$NS" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    EOT
  }

  depends_on = [
    helm_release.lb_controller,
    helm_release.hindsight,
    kubernetes_ingress_v1.control_plane_public,
    kubernetes_ingress_v1.control_plane_internal,
    # Keep the controller's IRSA role/policy alive until alb_drain finishes, so the
    # controller retains its elasticloadbalancing IAM permissions while draining.
    module.lb_controller_irsa,
    # CRITICAL: keep the VPC (and its NAT gateway) alive until alb_drain finishes.
    # The controller pods reach the ELB API (elasticloadbalancing.<region>.
    # amazonaws.com) via the NAT gateway. Terraform destroys a resource before the
    # things it depends on, and the VPC module's NAT gateway is NOT in this root
    # module's state, so without this dependency Terraform tears the NAT gateway
    # down at the start of destroy -- in parallel with alb_drain -- severing the
    # controller's only egress. The controller then logs
    # 'Post "https://elasticloadbalancing...": dial tcp ...: i/o timeout' and can
    # never delete the ALB or process finalizers (the real cause of the teardown
    # deadlock). Depending on module.vpc keeps NAT/egress up until drain completes.
    module.vpc,
  ]
}
