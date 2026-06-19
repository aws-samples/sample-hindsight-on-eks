# LiteLLM proxy deployment for Bedrock embeddings/reranker auth
# Hindsight's litellm-sdk provider passes api_key to litellm which overrides SigV4 signing.
# This proxy handles Bedrock auth via IRSA (pod IAM role) and exposes an OpenAI-compatible API.

# Dedicated service account for the litellm proxy with Bedrock access via IRSA
resource "kubernetes_service_account" "litellm_proxy" {
  metadata {
    name      = "litellm-proxy"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.hindsight_irsa.iam_role_arn
    }
  }

  depends_on = [kubernetes_namespace.hindsight]
}

resource "kubernetes_config_map" "litellm_proxy" {
  metadata {
    name      = "litellm-proxy-config"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  data = {
    "config.yaml" = yamlencode({
      model_list = [
        {
          model_name = "bedrock-embed"
          litellm_params = {
            model           = "bedrock/amazon.titan-embed-text-v2:0"
            aws_region_name = var.aws_region
          }
        },
        {
          model_name = "bedrock-rerank"
          litellm_params = {
            model           = "bedrock/arn:aws:bedrock:${var.aws_region}::foundation-model/cohere.rerank-v3-5:0"
            aws_region_name = var.aws_region
          }
        }
      ]
    })
  }

  depends_on = [kubernetes_namespace.hindsight]
}

resource "kubernetes_deployment" "litellm_proxy" {
  metadata {
    name      = "litellm-proxy"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
    labels = {
      app = "litellm-proxy"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "litellm-proxy"
      }
    }

    template {
      metadata {
        labels = {
          app = "litellm-proxy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.litellm_proxy.metadata[0].name

        container {
          name  = "litellm"
          image = "ghcr.io/berriai/litellm:main-v1.83.10-stable"

          args = ["--config", "/app/config.yaml", "--port", "4000"]

          port {
            container_port = 4000
            protocol       = "TCP"
          }

          env {
            name  = "AWS_REGION_NAME"
            value = var.aws_region
          }

          # Reduce litellm's overhead - disable telemetry and logging
          env {
            name  = "LITELLM_TELEMETRY"
            value = "False"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "500m"
              memory = "2Gi"
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config.yaml"
            sub_path   = "config.yaml"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/health/liveliness"
              port = 4000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/health/readiness"
              port = 4000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.litellm_proxy.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.hindsight,
    module.hindsight_irsa
  ]
}

resource "kubernetes_service" "litellm_proxy" {
  metadata {
    name      = "litellm-proxy"
    namespace = kubernetes_namespace.hindsight.metadata[0].name
  }

  spec {
    selector = {
      app = "litellm-proxy"
    }

    port {
      port        = 4000
      target_port = 4000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_namespace.hindsight]
}
