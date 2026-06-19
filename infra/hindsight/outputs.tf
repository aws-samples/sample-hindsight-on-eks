output "hindsight_api_url" {
  description = "Hindsight API URL"
  value       = var.public_endpoint ? "https://${var.hindsight_domain}" : "http://localhost:8888 (via: kubectl port-forward -n hindsight svc/hindsight-api 8888:8888)"
}

output "control_plane_url" {
  description = "Hindsight Control Plane URL"
  value       = var.public_endpoint ? "https://cp.${var.hindsight_domain}" : "http://localhost:3000 (via: kubectl port-forward -n hindsight svc/hindsight-control-plane 3000:3000)"
}

output "rds_endpoint" {
  description = "RDS cluster endpoint"
  value       = aws_rds_cluster.hindsight.endpoint
}

output "s3_bucket" {
  description = "S3 bucket name for file storage"
  value       = aws_s3_bucket.hindsight.id
}

output "eks_cluster_name" {
  description = "EKS cluster name (for kubectl config)"
  value       = module.eks.cluster_name
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID in use (created or brought-in)"
  value       = local.cognito_user_pool_id
}

output "cognito_hosted_ui_domain" {
  description = "Cognito hosted UI domain"
  value       = local.cognito_domain
}

output "port_forward_commands" {
  description = "kubectl port-forward commands for internal (non-public) deployments"
  value = var.public_endpoint ? "n/a (public endpoint enabled)" : join("\n", [
    "kubectl port-forward -n hindsight svc/hindsight-api 8888:8888",
    "kubectl port-forward -n hindsight svc/hindsight-control-plane 3000:3000",
  ])
}

output "opencode_mcp_config" {
  description = "Template OpenCode MCP server configuration. Replace <your-alias> with your Cognito username before pasting into opencode.json."
  value = jsonencode({
    hindsight = {
      type = "remote"
      url  = "${var.public_endpoint ? "https://${var.hindsight_domain}" : "http://localhost:8888"}/mcp/<your-alias>/"
      oauth = {
        clientId = aws_cognito_user_pool_client.hindsight_mcp.id
        scope    = "openid email profile"
      }
    }
    hindsight-shared = {
      type = "remote"
      url  = "${var.public_endpoint ? "https://${var.hindsight_domain}" : "http://localhost:8888"}/mcp/shared/"
      oauth = {
        clientId = aws_cognito_user_pool_client.hindsight_mcp.id
        scope    = "openid email profile"
      }
    }
  })
}

output "mcp_client_id" {
  description = "Cognito MCP OAuth client ID (for opencode.json)"
  value       = aws_cognito_user_pool_client.hindsight_mcp.id
}
