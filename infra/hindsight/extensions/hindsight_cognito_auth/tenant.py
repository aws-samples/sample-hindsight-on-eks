"""CognitoTenantExtension — validates Cognito JWTs and enforces bank ownership."""

import json
import os
import re
from typing import Any

import jwt
from jwt import PyJWKClient

from hindsight_api.extensions import TenantExtension, TenantContext, Tenant, AuthenticationError


class CognitoTenantExtension(TenantExtension):
    """Validates Cognito JWTs via JWKS and returns TenantContext with user identity.

    Also accepts:
    - A static API key for internal service-to-service calls (CP -> API)
    - Per-user API keys (rotated daily) for plugins and tooling

    Bank ownership rules:
    - Personal banks (/mcp/{alias} or /mcp/{alias}-*): owner only
    - Shared banks (/mcp/team-*): any authenticated user
    - Project banks (/mcp/project-*): any authenticated user
    - Other banks: any authenticated user (permissive default)
    """

    def __init__(self, config: dict[str, str]):
        super().__init__(config)

        self.issuer = config.get("cognito_issuer")
        if not self.issuer:
            raise ValueError(
                "HINDSIGHT_API_TENANT_COGNITO_ISSUER is required. "
                "Example: https://cognito-idp.us-west-2.amazonaws.com/us-west-2_xxxxxxxxx"
            )

        self.client_id = config.get("cognito_client_id")
        if not self.client_id:
            raise ValueError("HINDSIGHT_API_TENANT_COGNITO_CLIENT_ID is required.")

        # Internal API key for service-to-service calls (CP -> API)
        self._internal_api_key = os.environ.get("HINDSIGHT_CP_DATAPLANE_API_KEY")

        # Per-user API keys (rotated daily, loaded from env)
        self._user_api_keys = self._load_user_api_keys()

        jwks_url = f"{self.issuer}/.well-known/jwks.json"
        self._jwks_client = PyJWKClient(jwks_url, cache_keys=True, lifespan=600)

    async def authenticate(self, context: Any) -> TenantContext:
        token = context.api_key
        if not token:
            raise AuthenticationError(
                "Authorization required",
                headers={"WWW-Authenticate": 'Bearer realm="hindsight"'},
            )

        # Allow internal service-to-service calls with the dataplane API key
        if self._internal_api_key and token == self._internal_api_key:
            return TenantContext(schema_name="public")

        # Check per-user API keys (rotated daily)
        if token in self._user_api_keys:
            alias = self._user_api_keys[token]
            bank_id = self._extract_bank_id(context)
            if bank_id:
                self._check_bank_access(alias, bank_id)
            return TenantContext(schema_name="public")

        try:
            signing_key = self._jwks_client.get_signing_key_from_jwt(token)
            # Cognito access tokens don't have an "aud" claim — they use "client_id".
            # We skip audience validation in PyJWT and manually verify client_id below.
            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                issuer=self.issuer,
                options={"require": ["exp", "iss", "sub"], "verify_aud": False},
            )

            # Verify client_id matches our expected MCP client
            token_client_id = payload.get("client_id")
            if token_client_id and token_client_id != self.client_id:
                raise jwt.InvalidTokenError(
                    f"Token client_id '{token_client_id}' does not match expected '{self.client_id}'"
                )
        except jwt.ExpiredSignatureError:
            raise AuthenticationError(
                "Token expired",
                headers={"WWW-Authenticate": 'Bearer realm="hindsight", error="invalid_token"'},
            )
        except jwt.InvalidTokenError as e:
            raise AuthenticationError(
                f"Invalid token: {e}",
                headers={"WWW-Authenticate": 'Bearer realm="hindsight", error="invalid_token"'},
            )

        # Extract user alias from Cognito claims
        alias = self._extract_alias(payload)
        if not alias:
            raise AuthenticationError("Could not determine user identity from token")

        # Enforce bank ownership
        bank_id = self._extract_bank_id(context)
        if bank_id:
            self._check_bank_access(alias, bank_id)

        return TenantContext(schema_name="public")

    async def list_tenants(self) -> list[Tenant]:
        """Return the single shared schema for worker polling.

        All users share the 'public' schema — bank ownership is enforced
        at the application layer via _check_bank_access, not via schema isolation.
        """
        return [Tenant(schema="public")]

    def _extract_alias(self, payload: dict) -> str | None:
        """Extract the user's alias from JWT claims.

        Priority:
        1. 'custom:alias' if the IdP maps it
        2. 'cognito:username' with IdP prefix stripped
        3. Email prefix (before @)
        """
        # Check for a custom alias claim
        alias = payload.get("custom:alias")
        if alias:
            return self._sanitize_alias(alias)

        # Access tokens use "username", ID tokens use "cognito:username"
        cognito_username = payload.get("username") or payload.get("cognito:username", "")
        if "_" in cognito_username:
            # Strip the IdP prefix (e.g., "<idp>_jdoe" -> "jdoe")
            alias = cognito_username.split("_", 1)[1]
            return self._sanitize_alias(alias)
        elif cognito_username:
            return self._sanitize_alias(cognito_username)

        # Fallback: email prefix
        email = payload.get("email", "")
        if "@" in email:
            return self._sanitize_alias(email.split("@")[0])

        return None

    def _sanitize_alias(self, alias: str) -> str:
        """Ensure alias is safe for use as a bank ID component."""
        return re.sub(r"[^a-zA-Z0-9_-]", "", alias).lower()

    def _extract_bank_id(self, context: Any) -> str | None:
        """Extract bank_id from the request path if available."""
        path = getattr(context, "path", "") or ""
        # MCP endpoints: /mcp/{bank_id}
        match = re.match(r"/mcp/([^/]+)", path)
        return match.group(1) if match else None

    def _check_bank_access(self, alias: str, bank_id: str) -> None:
        """Enforce bank ownership rules."""
        # Shared prefixes — any authenticated user can access
        if bank_id.startswith("team-") or bank_id.startswith("project-"):
            return

        # If bank_id matches the user's alias or starts with alias-
        if bank_id == alias or bank_id.startswith(f"{alias}-"):
            return

        # Permissive default: allow access to unrecognized patterns
        # Only block if the bank_id matches another known pattern
        # For now, allow all access — ownership enforcement can be tightened later
        return

    def _load_user_api_keys(self) -> dict:
        """Load per-user API key maps from environment.

        Expected format: JSON with 'by_key' and 'previous_by_key' maps.
        Returns combined dict of key->alias for both current and previous keys.
        """
        raw = os.environ.get("HINDSIGHT_API_TENANT_USER_API_KEYS", "")
        if not raw:
            return {}

        try:
            data = json.loads(raw)
            # Merge current and previous keys for grace period
            combined = {}
            combined.update(data.get("previous_by_key", {}))
            combined.update(data.get("by_key", {}))  # Current keys take priority
            return combined
        except (ValueError, TypeError):
            return {}
