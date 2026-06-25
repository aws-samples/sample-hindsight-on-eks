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

      # Delete every ingress in the namespace (chart-managed API ingress +
      # Terraform-managed Control Plane ingress). The AWS Load Balancer Controller
      # is still running at this point (this resource is destroyed before it), so
      # it processes the group.ingress.k8s.aws/<group> finalizers, deletes its
      # TargetGroupBindings, and detaches/deletes the shared ALB. --wait=false so
      # we don't block on the finalizer here; we poll for completion below.
      kubectl delete ingress --all -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true

      # Wait for the controller to FINISH: both the Ingress objects AND their
      # TargetGroupBindings must be gone, and the shared ALB removed. Polling all
      # three (not just the ALB) is the key correctness fix -- leftover Ingress or
      # TargetGroupBinding finalizers are exactly what otherwise deadlock the later
      # destroy of the Control Plane ingress and the hindsight namespace. The
      # controller normally clears these within a minute or two; we allow ~8.
      for i in $(seq 1 48); do
        ING="$(kubectl get ingress -n "$NS" -o name 2>/dev/null | wc -l | tr -d ' ')"
        TGB="$(kubectl get targetgroupbindings -n "$NS" -o name 2>/dev/null | wc -l | tr -d ' ')"
        ALB="$(aws elbv2 describe-load-balancers --region "$REGION" --profile "$PROFILE" \
          --query "length(LoadBalancers[?contains(LoadBalancerName, '$ALB_PREFIX')])" \
          --output text 2>/dev/null || echo ERR)"
        if [ "$ING" = "0" ] && [ "$TGB" = "0" ] && [ "$ALB" = "0" ]; then
          echo "alb_drain: controller finished (ingresses, TargetGroupBindings, and ALB all gone)."
          exit 0
        fi
        echo "alb_drain: waiting for controller cleanup (ingress=$ING tgb=$TGB alb=$ALB) ($i/48)..."
        sleep 10
      done

      # Fallback safety valve: the controller did not converge in time (e.g. it
      # stopped reconciling). Clear the lingering finalizers directly so the later
      # Terraform deletes of the Control Plane ingress and the namespace do not
      # deadlock. We do NOT remove the controller or its webhooks here -- doing so
      # blocks ingress mutation and causes phantom TargetGroupBindings; letting the
      # finalizers go while the controller is still up is the safe action.
      echo "alb_drain: controller did not converge; clearing lingering finalizers."
      for ing in $(kubectl get ingress -n "$NS" -o name 2>/dev/null); do
        kubectl patch "$ing" -n "$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
      done
      for tgb in $(kubectl get targetgroupbindings -n "$NS" -o name 2>/dev/null); do
        kubectl patch "$tgb" -n "$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
      done
    EOT
  }

  depends_on = [
    helm_release.lb_controller,
    helm_release.hindsight,
    kubernetes_ingress_v1.control_plane_public,
    kubernetes_ingress_v1.control_plane_internal,
  ]
}
