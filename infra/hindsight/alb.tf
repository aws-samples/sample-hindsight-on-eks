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

      # Build an isolated kubeconfig using the same profile/region as the providers.
      if ! aws eks update-kubeconfig \
        --name "${self.triggers.cluster_name}" \
        --region "${self.triggers.region}" \
        --profile "${self.triggers.profile}" >/dev/null 2>&1; then
        echo "alb_drain: cluster unreachable; assuming already destroyed, skipping."
        exit 0
      fi

      # Delete every ingress in the namespace (chart-managed API ingress +
      # Terraform-managed Control Plane ingress). Best-effort; the controller
      # processes the finalizer and detaches each from the shared ALB.
      kubectl delete ingress --all -n "${self.triggers.namespace}" \
        --ignore-not-found --timeout=180s || true

      # Wait until the shared ALB (tagged by the controller with the ingress
      # group) is gone, so the controller has finished its cleanup before it is
      # itself removed. Times out after ~5 minutes as a safety valve.
      for i in $(seq 1 30); do
        COUNT="$(aws elbv2 describe-load-balancers \
          --region "${self.triggers.region}" \
          --profile "${self.triggers.profile}" \
          --query "length(LoadBalancers[?contains(LoadBalancerName, '${self.triggers.alb_name_prefix}')])" \
          --output text 2>/dev/null || echo ERR)"
        if [ "$COUNT" = "0" ]; then
          echo "alb_drain: ALB drained."
          exit 0
        fi
        if [ "$COUNT" = "ERR" ] || [ "$COUNT" = "None" ]; then
          echo "alb_drain: ALB query failed (transient?); retrying ($i/30)..."
        else
          echo "alb_drain: waiting for ALB to drain ($i/30)..."
        fi
        sleep 10
      done
      echo "alb_drain: timed out waiting for ALB; continuing (see troubleshooting)."
    EOT
  }

  depends_on = [
    helm_release.lb_controller,
    helm_release.hindsight,
    kubernetes_ingress_v1.control_plane_public,
    kubernetes_ingress_v1.control_plane_internal,
  ]
}
