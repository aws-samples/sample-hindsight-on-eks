# Terraform-created sample Cognito pool (active when create_identity_provider = true).
# Brought-in pools are referenced directly via var.cognito_user_pool_id.

locals {
  create_pool = var.create_identity_provider

  # A unique default domain prefix when the user didn't supply one.
  generated_domain_prefix = "${var.project_name}-${random_id.cognito_suffix.hex}"
  effective_domain_prefix = coalesce(var.cognito_domain_prefix, local.generated_domain_prefix)
}

resource "random_id" "cognito_suffix" {
  byte_length = 4
}

resource "aws_cognito_user_pool" "hindsight" {
  count = local.create_pool ? 1 : 0

  name                     = "${var.project_name}-pool"
  auto_verified_attributes = ["email"]

  username_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = local.tags
}

resource "aws_cognito_user_pool_domain" "hindsight" {
  count = local.create_pool ? 1 : 0

  domain       = local.effective_domain_prefix
  user_pool_id = aws_cognito_user_pool.hindsight[0].id
}

# Optional federated IdP attached to the created pool.
resource "aws_cognito_identity_provider" "federation" {
  count = local.create_pool && var.federation != null ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.hindsight[0].id
  provider_name = var.federation.provider_name
  provider_type = var.federation.type

  provider_details = var.federation.type == "SAML" ? {
    MetadataURL = var.federation.metadata_url
    } : {
    oidc_issuer               = var.federation.oidc_issuer
    client_id                 = var.federation.oidc_client_id
    client_secret             = var.federation.oidc_client_secret
    authorize_scopes          = var.federation.oidc_scopes
    attributes_request_method = var.federation.oidc_attributes_request_method
  }

  attribute_mapping = var.federation.attribute_mapping
}
