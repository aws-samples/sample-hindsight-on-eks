# Cognito locals resolved from either the Terraform-created pool or a brought-in pool.
locals {
  cognito_user_pool_id  = local.create_pool ? aws_cognito_user_pool.hindsight[0].id : var.cognito_user_pool_id
  cognito_domain_prefix = local.create_pool ? aws_cognito_user_pool_domain.hindsight[0].domain : var.cognito_domain_prefix
  cognito_domain        = "${local.cognito_domain_prefix}.auth.${var.aws_region}.amazoncognito.com"
  cognito_issuer        = "https://cognito-idp.${var.aws_region}.amazonaws.com/${local.cognito_user_pool_id}"

  # IdP name: federation provider on the created pool, else the BYO var.
  cognito_idp_name   = local.create_pool ? (var.federation != null ? var.federation.provider_name : "") : var.cognito_idp_name
  cognito_idp_prefix = local.cognito_idp_name == "" ? "" : "${local.cognito_idp_name}_"
}

# MCP OAuth Client (public — for OpenCode CLI PKCE flow)
resource "aws_cognito_user_pool_client" "hindsight_mcp" {
  name         = "hindsight-mcp-${terraform.workspace}"
  user_pool_id = local.cognito_user_pool_id

  generate_secret = false # Public client for PKCE

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = [
    "http://127.0.0.1:19876/mcp/oauth/callback",
    "http://localhost:19876/mcp/oauth/callback",
    "http://127.0.0.1:19876/callback",
    "http://localhost:19876/callback",
    "http://127.0.0.1:8080/callback",
    "http://localhost:8080/callback",
  ]

  access_token_validity  = 12 # hours
  id_token_validity      = 12 # hours
  refresh_token_validity = 12 # hours

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "hours"
  }

  supported_identity_providers = compact(["COGNITO", local.cognito_idp_name])

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  depends_on = [aws_cognito_identity_provider.federation]
}

# ALB Client (confidential — for browser-based Control Plane OIDC auth)
resource "aws_cognito_user_pool_client" "hindsight_alb" {
  count = var.public_endpoint ? 1 : 0

  name         = "hindsight-alb-${terraform.workspace}"
  user_pool_id = local.cognito_user_pool_id

  generate_secret = true # ALB needs client secret

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = [
    "https://${var.hindsight_domain}/oauth2/idpresponse",
    "https://cp.${var.hindsight_domain}/oauth2/idpresponse",
  ]

  logout_urls = [
    "https://${var.hindsight_domain}/",
    "https://cp.${var.hindsight_domain}/",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 12

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "hours"
  }

  supported_identity_providers = compact(["COGNITO", local.cognito_idp_name])

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  depends_on = [aws_cognito_identity_provider.federation]
}
