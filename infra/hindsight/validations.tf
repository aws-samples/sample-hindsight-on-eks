# Cross-variable validation. terraform_data + preconditions fail fast at plan
# time with clear messages when flag combinations are incomplete.

resource "terraform_data" "validate_public_endpoint" {
  lifecycle {
    precondition {
      condition     = !var.public_endpoint || (var.hosted_zone_id != null && var.hindsight_domain != null)
      error_message = "public_endpoint = true requires both hosted_zone_id and hindsight_domain to be set."
    }
  }
}

resource "terraform_data" "validate_byo_identity" {
  lifecycle {
    precondition {
      condition     = var.create_identity_provider || (var.cognito_user_pool_id != null && var.cognito_domain_prefix != null)
      error_message = "create_identity_provider = false requires both cognito_user_pool_id and cognito_domain_prefix (bring your own pool)."
    }
  }
}

resource "terraform_data" "validate_federation_requires_created_pool" {
  lifecycle {
    precondition {
      condition     = var.federation == null || var.create_identity_provider
      error_message = "federation can only be set when create_identity_provider = true (it attaches to the Terraform-created pool)."
    }
  }
}

resource "terraform_data" "validate_federation_fields" {
  lifecycle {
    precondition {
      condition = var.federation == null || (
        var.federation.type == "SAML" ? var.federation.metadata_url != null : true
        ) && (
        var.federation.type == "OIDC" ? (
          var.federation.oidc_issuer != null &&
          var.federation.oidc_client_id != null &&
          var.federation.oidc_client_secret != null
        ) : true
      )
      error_message = "SAML federation requires metadata_url; OIDC federation requires oidc_issuer, oidc_client_id, and oidc_client_secret."
    }
  }
}
