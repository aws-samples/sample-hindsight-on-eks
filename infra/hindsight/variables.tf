variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "hindsight"
}

variable "my_ip" {
  description = "Your public IP address for ALB security group (CIDR notation). Optional — omit to rely solely on Cognito auth."
  type        = string
  default     = null
}

variable "db_password" {
  description = "RDS PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "hindsight_api_key" {
  description = "API key for Hindsight tenant authentication. Optional — omit when using Cognito auth."
  type        = string
  sensitive   = true
  default     = null
}

variable "bedrock_model_id" {
  description = "Bedrock model ID for LLM (e.g. openai.gpt-oss-120b-1:0)"
  type        = string
  default     = "openai.gpt-oss-120b-1:0"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID. Required only when public_endpoint = true."
  type        = string
  default     = null
}

variable "hindsight_domain" {
  description = "FQDN for the Hindsight endpoint (e.g., hindsight.example.com). Required only when public_endpoint = true."
  type        = string
  default     = null
}

variable "cognito_user_pool_id" {
  description = "Existing Cognito User Pool ID. Required only when create_identity_provider = false."
  type        = string
  default     = null
}

variable "cognito_idp_name" {
  description = "Name of the federated identity provider in the Cognito pool. Leave empty for default Cognito-only deployments. Used only when a SAML/OIDC IdP is configured (see docs/federation.md)."
  type        = string
  default     = ""
}

variable "cognito_domain_prefix" {
  description = "Cognito hosted UI domain prefix. When create_identity_provider = true this names the created domain (a unique default is generated if null); when false it must match your existing pool's domain."
  type        = string
  default     = null
}

# --- Deployment mode flags ---

variable "create_identity_provider" {
  description = "When true, Terraform creates a sample Cognito user pool and hosted-UI domain. When false, bring an existing pool via cognito_user_pool_id + cognito_domain_prefix."
  type        = bool
  default     = true
}

variable "public_endpoint" {
  description = "When true, exposes Hindsight publicly via an internet-facing ALB with Route 53 + ACM TLS (requires hosted_zone_id and hindsight_domain). When false, the ALB is internal and reached via kubectl port-forward."
  type        = bool
  default     = false
}

variable "federation" {
  description = "Optional SAML/OIDC identity provider to attach to the Terraform-created Cognito pool. Only valid when create_identity_provider = true. Leave null for a Cognito-only sample pool."
  type = object({
    type                           = string # "SAML" | "OIDC" (maps to provider_type)
    provider_name                  = string # e.g. "MyCorpIdP"
    metadata_url                   = optional(string)
    oidc_issuer                    = optional(string)
    oidc_client_id                 = optional(string)
    oidc_client_secret             = optional(string)
    oidc_scopes                    = optional(string, "openid email profile")
    oidc_attributes_request_method = optional(string, "GET")
    attribute_mapping              = optional(map(string), { email = "email" })
  })
  default = null

  validation {
    condition     = var.federation == null || contains(["SAML", "OIDC"], try(var.federation.type, ""))
    error_message = "federation.type must be \"SAML\" or \"OIDC\"."
  }
}

# --- Compute mode ---

variable "compute_mode" {
  description = "EKS compute provider: \"fargate\" (default, runs all pods on Fargate) or \"auto\" (EKS Auto Mode managed EC2 nodes). Fargate is the tested default; Auto Mode is AWS's recommended path and an opt-in alternative. The mode is chosen at cluster creation — switching in place is not supported and effectively recreates the cluster."
  type        = string
  default     = "fargate"

  validation {
    condition     = contains(["fargate", "auto"], var.compute_mode)
    error_message = "compute_mode must be \"fargate\" or \"auto\"."
  }
}
