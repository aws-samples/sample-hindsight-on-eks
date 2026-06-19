# IRSA role for Hindsight service account (S3 + Bedrock access)
module "hindsight_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix = "${var.project_name}-api-"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["hindsight:hindsight", "hindsight:litellm-proxy"]
    }
  }

  role_policy_arns = {
    s3      = aws_iam_policy.hindsight_s3.arn
    bedrock = aws_iam_policy.hindsight_bedrock.arn
  }

  tags = local.tags
}

# Kubernetes secret for Hindsight (Helm's existingSecret feature)
resource "kubernetes_secret" "hindsight" {
  metadata {
    name      = "hindsight-secret"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  data = merge(
    {
      "postgres-password" = var.db_password
    },
    var.hindsight_api_key != null ? {
      "HINDSIGHT_API_TENANT_API_KEY"   = var.hindsight_api_key
      "HINDSIGHT_CP_DATAPLANE_API_KEY" = var.hindsight_api_key
      } : {
      # Control Plane still needs a key to talk to the API server
      # Generate a deterministic one from the database password
      "HINDSIGHT_CP_DATAPLANE_API_KEY" = var.db_password
    }
  )

  depends_on = [kubernetes_namespace.hindsight]
}

# ConfigMap containing the Cognito auth extension Python source
resource "kubernetes_config_map" "cognito_extension" {
  metadata {
    name      = "hindsight-cognito-auth"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  data = {
    "__init__.py" = file("${path.module}/extensions/hindsight_cognito_auth/__init__.py")
    "tenant.py"   = file("${path.module}/extensions/hindsight_cognito_auth/tenant.py")
    "oauth.py"    = file("${path.module}/extensions/hindsight_cognito_auth/oauth.py")
  }

  depends_on = [kubernetes_namespace.hindsight]
}

# Security group for ALB (Cognito auth replaces IP allowlisting)
resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  vpc_id      = module.vpc.vpc_id

  # HTTPS from anywhere (Cognito auth replaces IP allowlisting)
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP for redirect to HTTPS. Scoped to my_ip when provided; the ALB listener
  # only performs an HTTP->HTTPS redirect, and Cognito enforces auth on HTTPS.
  # Omitted entirely when my_ip is not set to avoid opening port 80 to the world.
  dynamic "ingress" {
    for_each = var.my_ip != null ? [var.my_ip] : []
    content {
      description = "HTTP for redirect (allowlisted)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Allow ALB to reach Fargate pods (cluster SG) on application ports
resource "aws_security_group_rule" "alb_to_pods" {
  type                     = "ingress"
  from_port                = 8888
  to_port                  = 8888
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to Hindsight API pods"
}

resource "aws_security_group_rule" "alb_to_control_plane_pods" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to Hindsight Control Plane pods"
}

resource "helm_release" "hindsight" {
  name       = "hindsight"
  repository = "oci://ghcr.io/vectorize-io/charts"
  chart      = "hindsight"
  version    = "0.5.4"
  namespace  = kubernetes_namespace.hindsight.metadata[0].name

  # Fargate pod scheduling + image pull + Bedrock init can take 5+ minutes
  timeout = 600
  wait    = true

  values = [file("${path.module}/values/hindsight.yaml")]

  # Override values that depend on Terraform resources
  set {
    name  = "existingSecret"
    value = kubernetes_secret.hindsight.metadata[0].name
  }

  set {
    name  = "postgresql.external.host"
    value = aws_rds_cluster.hindsight.endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.hindsight_irsa.iam_role_arn
  }

  set {
    name  = "api.env.HINDSIGHT_API_FILE_STORAGE_S3_BUCKET"
    value = aws_s3_bucket.hindsight.id
  }

  set {
    name  = "api.env.HINDSIGHT_API_FILE_STORAGE_S3_REGION"
    value = var.aws_region
  }

  set {
    name  = "api.env.HINDSIGHT_API_LLM_MODEL"
    value = var.bedrock_model_id
  }

  set {
    name  = "api.env.AWS_REGION_NAME"
    value = var.aws_region
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/security-groups"
    value = aws_security_group.alb.id
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/group\\.name"
    value = "hindsight"
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
    value = var.public_endpoint ? "internet-facing" : "internal"
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/listen-ports"
    value = var.public_endpoint ? "[{\"HTTPS\":443}\\,{\"HTTP\":80}]" : "[{\"HTTP\":80}]"
  }

  # HTTPS certificate + ssl-redirect only when public.
  dynamic "set" {
    for_each = var.public_endpoint ? [1] : []
    content {
      name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn"
      value = aws_acm_certificate_validation.hindsight[0].certificate_arn
    }
  }

  dynamic "set" {
    for_each = var.public_endpoint ? [1] : []
    content {
      name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/ssl-redirect"
      value = "443"
    }
  }

  # Cognito auth extension configuration
  set {
    name  = "api.env.HINDSIGHT_API_TENANT_EXTENSION"
    value = "hindsight_cognito_auth.tenant:CognitoTenantExtension"
  }

  set {
    name  = "api.env.HINDSIGHT_API_HTTP_EXTENSION"
    value = "hindsight_cognito_auth.oauth:CognitoOAuthExtension"
  }

  set {
    name  = "api.env.HINDSIGHT_API_TENANT_COGNITO_ISSUER"
    value = local.cognito_issuer
  }

  set {
    name  = "api.env.HINDSIGHT_API_TENANT_COGNITO_DOMAIN"
    value = local.cognito_domain
  }

  set {
    name  = "api.env.HINDSIGHT_API_TENANT_COGNITO_CLIENT_ID"
    value = aws_cognito_user_pool_client.hindsight_mcp.id
  }

  set {
    name  = "api.env.PYTHONPATH"
    value = "/app"
  }

  # Mount the extension source into the API container
  set {
    name  = "api.extraVolumes[0].name"
    value = "cognito-auth-ext"
  }

  set {
    name  = "api.extraVolumes[0].configMap.name"
    value = kubernetes_config_map.cognito_extension.metadata[0].name
  }

  set {
    name  = "api.extraVolumeMounts[0].name"
    value = "cognito-auth-ext"
  }

  set {
    name  = "api.extraVolumeMounts[0].mountPath"
    value = "/app/hindsight_cognito_auth"
  }

  set {
    name  = "api.extraVolumeMounts[0].readOnly"
    value = "true"
  }

  # Mount the extension source into the worker container
  set {
    name  = "worker.extraVolumes[0].name"
    value = "cognito-auth-ext"
  }

  set {
    name  = "worker.extraVolumes[0].configMap.name"
    value = kubernetes_config_map.cognito_extension.metadata[0].name
  }

  set {
    name  = "worker.extraVolumeMounts[0].name"
    value = "cognito-auth-ext"
  }

  set {
    name  = "worker.extraVolumeMounts[0].mountPath"
    value = "/app/hindsight_cognito_auth"
  }

  set {
    name  = "worker.extraVolumeMounts[0].readOnly"
    value = "true"
  }

  # Mount per-user API keys secret as environment variables
  # The chart doesn't support extraEnvFrom natively, so we patch post-deploy below.

  depends_on = [
    helm_release.lb_controller,
    aws_rds_cluster_instance.hindsight,
    kubernetes_secret.hindsight,
    kubernetes_service.litellm_proxy,
    kubernetes_config_map.cognito_extension,
  ]
}

# Patch the API deployment to mount the per-user API keys secret as envFrom
# The Hindsight Helm chart doesn't support extraEnvFrom, so we patch directly.
resource "null_resource" "patch_api_envfrom" {
  triggers = {
    helm_revision = helm_release.hindsight.metadata[0].revision
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl patch deployment hindsight-api -n hindsight \
        --type=json \
        -p '[{"op": "add", "path": "/spec/template/spec/containers/0/envFrom/-", "value": {"secretRef": {"name": "hindsight-api-keys"}}}]'
    EOT
  }

  depends_on = [helm_release.hindsight]
}

# Data source to read the ALB hostname after the ingress is created
data "kubernetes_ingress_v1" "hindsight" {
  metadata {
    name      = "hindsight"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  depends_on = [helm_release.hindsight]
}

# Secret for ALB OIDC authentication (Cognito ALB client credentials)
resource "kubernetes_secret" "alb_oidc" {
  count = var.public_endpoint ? 1 : 0

  metadata {
    name      = "hindsight-alb-oidc-secret"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  data = {
    clientId     = aws_cognito_user_pool_client.hindsight_alb[0].id
    clientSecret = aws_cognito_user_pool_client.hindsight_alb[0].client_secret
  }

  depends_on = [kubernetes_namespace.hindsight]
}

# RBAC: Allow the ALB controller to read the OIDC secret in the hindsight namespace
resource "kubernetes_role" "alb_controller_secret_reader" {
  count = var.public_endpoint ? 1 : 0

  metadata {
    name      = "alb-controller-secret-reader"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    verbs          = ["get"]
    resource_names = [kubernetes_secret.alb_oidc[0].metadata[0].name]
  }
}

resource "kubernetes_role_binding" "alb_controller_secret_reader" {
  count = var.public_endpoint ? 1 : 0

  metadata {
    name      = "alb-controller-secret-reader"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.alb_controller_secret_reader[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }
}

# Control Plane ingress — PUBLIC variant (ALB OIDC via Cognito hosted UI).
resource "kubernetes_ingress_v1" "control_plane_public" {
  count = var.public_endpoint ? 1 : 0

  metadata {
    name      = "hindsight-control-plane"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/group.name"      = "hindsight"
      "alb.ingress.kubernetes.io/group.order"     = "1"
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ "HTTPS" = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate_validation.hindsight[0].certificate_arn
      "alb.ingress.kubernetes.io/security-groups" = aws_security_group.alb.id
      "alb.ingress.kubernetes.io/auth-type"       = "oidc"
      "alb.ingress.kubernetes.io/auth-idp-oidc" = jsonencode({
        issuer                = local.cognito_issuer
        authorizationEndpoint = "https://${local.cognito_domain}/oauth2/authorize"
        tokenEndpoint         = "https://${local.cognito_domain}/oauth2/token"
        userInfoEndpoint      = "https://${local.cognito_domain}/oauth2/userInfo"
        secretName            = "hindsight-alb-oidc-secret"
      })
      "alb.ingress.kubernetes.io/auth-scope"                      = "openid email profile"
      "alb.ingress.kubernetes.io/auth-session-cookie"             = "AWSELBAuthSessionCookie"
      "alb.ingress.kubernetes.io/auth-session-timeout"            = "3600"
      "alb.ingress.kubernetes.io/auth-on-unauthenticated-request" = "authenticate"
    }
  }

  spec {
    ingress_class_name = "alb"
    rule {
      host = "cp.${var.hindsight_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "hindsight-control-plane"
              port {
                number = 3000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.hindsight,
    kubernetes_secret.alb_oidc,
    aws_acm_certificate_validation.hindsight,
  ]
}

# Control Plane ingress — INTERNAL variant (no OIDC; reached via port-forward).
resource "kubernetes_ingress_v1" "control_plane_internal" {
  count = var.public_endpoint ? 0 : 1

  metadata {
    name      = "hindsight-control-plane"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"            = "alb"
      "alb.ingress.kubernetes.io/scheme"       = "internal"
      "alb.ingress.kubernetes.io/target-type"  = "ip"
      "alb.ingress.kubernetes.io/group.name"   = "hindsight"
      "alb.ingress.kubernetes.io/group.order"  = "1"
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ "HTTP" = 80 }])
    }
  }

  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "hindsight-control-plane"
              port {
                number = 3000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.hindsight]
}
