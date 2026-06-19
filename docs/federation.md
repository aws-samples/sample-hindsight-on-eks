# Optional: SAML / OIDC federation

The default deployment uses a plain Cognito user pool with email/password (or Cognito-hosted-UI signup). To federate with an existing IdP — Okta, Microsoft Entra (Azure AD), Google Workspace, OneLogin, Auth0, Ping, or any SAML 2.0 / OIDC-compliant provider — follow this guide.

## Decision: SAML or OIDC?

| Use SAML if... | Use OIDC if... |
|---|---|
| Your IdP exposes only SAML metadata (typical for legacy enterprise IdPs). | Your IdP exposes an OIDC discovery URL (most modern IdPs). |
| You're integrating with an existing SAML-only SSO. | You want simpler attribute mapping. |

Both work with this sample. The Terraform resource is `aws_cognito_identity_provider`; the only differences are the `provider_type` and `provider_details` map.

There are two ways to federate, depending on who owns the pool:

- **Terraform creates the pool** (`create_identity_provider = true`, the default) — attach your IdP declaratively with the [`federation` variable](#federating-the-terraform-created-pool). This is the simplest path.
- **You bring an existing pool** (`create_identity_provider = false`) — add the IdP resource yourself in a `federation.tf` file and point `cognito_idp_name` at it. This is described in the [remaining sections](#bring-your-own-pool-where-to-add-the-federation-resources).

## Federating the Terraform-created pool

Use this when you want Terraform to create the sample Cognito pool (`create_identity_provider = true`) **and** attach your corporate IdP to it. Set the `federation` variable in `terraform.tfvars` and re-apply — no `federation.tf` file needed.

### SAML example

```hcl
federation = {
  type          = "SAML"
  provider_name = "MyCorpSAML"
  metadata_url  = "https://idp.example.com/federationmetadata.xml"
}
```

### OIDC example

```hcl
federation = {
  type               = "OIDC"
  provider_name      = "MyCorpOIDC"
  oidc_issuer        = "https://idp.example.com"
  oidc_client_id     = "abc123"
  oidc_client_secret = "shhh"
  oidc_scopes        = "openid email profile"
}
```

The `federation` object is only valid when `create_identity_provider = true`. After setting it, run `terraform apply`; Terraform creates the `aws_cognito_identity_provider` on the pool it manages and wires it into the app clients' `supported_identity_providers` automatically.

### Username prefix

`provider_name` becomes the username prefix in Cognito: federated usernames look like `<provider_name>_<sub>` (e.g., `MyCorpOIDC_abc-123`). The per-user key Lambdas strip this prefix via the `COGNITO_IDP_PREFIX` environment variable (Terraform sets it to `<provider_name>_` when `federation` is configured), so the resulting alias matches the underlying subject. See [Username claim format](#username-claim-format) for how the auth extension applies the same stripping.

### Limitation: non-discoverable OIDC issuers

This sample's `federation` block supports OIDC issuers that expose a standard discovery document at `https://<issuer>/.well-known/openid-configuration`. **Non-discoverable** OIDC issuers — those that require you to specify explicit `authorize`, `token`, `userinfo`, and `jwks` URLs instead of an issuer — are **not** supported by the `federation` variable. For those, bring your own pre-configured pool (`create_identity_provider = false`) with the IdP already attached, or add the `aws_cognito_identity_provider` resource yourself (see below) where you can set the full `provider_details` map.

## Bring your own pool: where to add the federation resources

Use this approach when you brought an existing pool (`create_identity_provider = false`) and want to attach an IdP to it, or when you need full control over `provider_details` (for example, a non-discoverable OIDC issuer).

Don't edit the sample's `auth.tf` directly. Instead, add a new file `infra/hindsight/federation.tf` (which the sample doesn't ship — it's user-defined). Terraform will pick up any `*.tf` file in the module root.

```bash
cd infra/hindsight
touch federation.tf
```

Add your IdP definition there as shown below.

## SAML federation

### Step 1: Define the IdP resource in `federation.tf`

```hcl
resource "aws_cognito_identity_provider" "saml" {
  user_pool_id  = var.cognito_user_pool_id
  provider_name = "MySAMLIdP"  # Free-form name; users will see this label on the Cognito sign-in page
  provider_type = "SAML"

  provider_details = {
    MetadataURL = "https://your-idp.example.com/sso/saml/metadata"
    # Or, if your IdP doesn't host metadata at a public URL:
    # MetadataFile = file("${path.module}/saml-metadata.xml")
  }

  attribute_mapping = {
    email    = "email"     # Right-hand side: the SAML attribute name your IdP sends
    username = "NameID"    # Most IdPs use NameID for the persistent user identifier
  }

  idp_identifiers = []  # Optional. Adds extra hosted-UI labels for your IdP.
}
```

### Step 2: Update `terraform.tfvars`

```hcl
cognito_idp_name = "MySAMLIdP"  # Must match `provider_name` above
```

### Step 3: Apply

```bash
terraform apply
```

The two Cognito app clients (MCP and ALB OIDC) automatically include this IdP in their `supported_identity_providers` because of the `compact()` expression in `auth.tf`:

```hcl
supported_identity_providers = compact(["COGNITO", var.cognito_idp_name])
```

This evaluates to `["COGNITO", "MySAMLIdP"]` after the change — meaning users can sign in with either Cognito-native credentials (useful for break-glass admin access) OR via your SAML IdP.

### Step 4: Configure your IdP

Your IdP needs to know:

- **Audience / Entity ID:** `urn:amazon:cognito:sp:<user-pool-id>` (substitute your pool ID, e.g., `urn:amazon:cognito:sp:us-west-2_xxxxxxxxx`)
- **Reply URL / ACS URL:** `https://<cognito_domain_prefix>.auth.<your-region>.amazoncognito.com/saml2/idpresponse`
- **Required SAML attributes to send:** at minimum `email`. Some IdPs need an explicit `NameID` mapping; others use email by default.

### Step 5: Test

Open `https://cp.<your-domain>` in a private browser window. The Cognito hosted UI should show two sign-in options now: "Sign in" (Cognito-native) and a button labeled `MySAMLIdP`. Click the IdP button; you'll be redirected to your IdP, authenticate, and bounced back to the dashboard.

## OIDC federation

### Step 1: Define the IdP resource in `federation.tf`

```hcl
resource "aws_cognito_identity_provider" "oidc" {
  user_pool_id  = var.cognito_user_pool_id
  provider_name = "MyOIDCIdP"
  provider_type = "OIDC"

  provider_details = {
    client_id                 = "<your-OIDC-client-id>"
    client_secret             = "<your-OIDC-client-secret>"
    authorize_scopes          = "openid email profile"
    oidc_issuer               = "https://your-idp.example.com"
    attributes_request_method = "GET"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"  # OIDC convention: `sub` is the persistent user identifier
  }
}
```

### Step 2-5: Same as SAML above

Update `terraform.tfvars`:
```hcl
cognito_idp_name = "MyOIDCIdP"
```

Run `terraform apply` and configure your IdP to accept the Cognito-hosted callback URL: `https://<cognito_domain_prefix>.auth.<your-region>.amazoncognito.com/oauth2/idpresponse`.

## Username claim format

When users sign in via a federated IdP, the `username` claim in their Cognito access token is prefixed with the IdP name:

| Sign-in method | `username` claim looks like |
|---|---|
| Cognito-native | `alice` |
| SAML federation (`MySAMLIdP`) | `MySAMLIdP_alice` |
| OIDC federation (`MyOIDCIdP`) | `MyOIDCIdP_alice` |

The auth extension's `_extract_alias()` function (see `infra/hindsight/extensions/hindsight_cognito_auth/tenant.py`) handles this automatically: if the username contains `_`, the extension splits on the first underscore and uses the right-hand side as the alias. So `MySAMLIdP_alice` becomes the alias `alice` (sanitized to lowercase alphanumerics, with `_` and `-` preserved).

This means the same user signing in via Cognito-native and via SAML produces a consistent alias — but only if the right-hand side after the IdP prefix matches. Configure your IdP's `username` (or `NameID`) attribute mapping to use a stable, low-cardinality identifier.

## API key prefix configuration

The Lambda functions that rotate and serve per-user API keys also strip the IdP prefix to map keys to aliases. They read `COGNITO_IDP_PREFIX` from environment, which Terraform populates conditionally:

```hcl
COGNITO_IDP_PREFIX = var.cognito_idp_name == "" ? "" : "${var.cognito_idp_name}_"
```

When `cognito_idp_name = ""` (Cognito-only), the Lambdas don't strip any prefix. When set (federated), the Lambdas strip `<provider_name>_`. No additional configuration needed.

## Troubleshooting

### `InvalidParameterException: SAML metadata URL is invalid`

The `MetadataURL` must be publicly reachable from AWS (Cognito fetches it during the `aws_cognito_identity_provider` create). If your IdP's metadata URL requires authentication or is behind a VPN, switch to the `MetadataFile` variant (read the XML into a local file and use `file()` in Terraform).

### Sign-in succeeds at the IdP but `redirect_uri_mismatch` after returning to Cognito

Confirm the callback URLs in the Cognito MCP app client (`auth.tf` → `aws_cognito_user_pool_client.hindsight_mcp` → `callback_urls`) include the URL your client uses. The sample includes `http://localhost:19876/callback`, `http://localhost:19876/mcp/oauth/callback`, and `http://localhost:8080/callback` by default. Add yours if different.

### Users authenticate but get `401 Unauthorized` on MCP requests

Check that the auth extension's alias-extraction logic handles your IdP's `username` claim shape. Run:

```bash
kubectl logs -n hindsight deployment/hindsight-api --tail=50 | grep "alias"
```

If you see attempts to extract an alias from an unusual format (e.g., `MySAMLIdP_email@domain.com`), the issue is that the alias-sanitization regex strips characters that would otherwise produce unique aliases. Adjust your IdP's `attribute_mapping` to send a clean identifier (typically `sub` for OIDC, or a custom attribute for SAML) instead of email.

### IdP doesn't appear on the Cognito hosted UI

Confirm:

1. `aws_cognito_identity_provider` resource was created (`terraform state show aws_cognito_identity_provider.saml`).
2. `cognito_idp_name` in your tfvars matches the IdP `provider_name` exactly.
3. You ran `terraform apply` AFTER setting `cognito_idp_name` (the change to the app clients' `supported_identity_providers` requires re-apply).
4. Wait 30 seconds and refresh — Cognito hosted UI caches IdP metadata briefly.
