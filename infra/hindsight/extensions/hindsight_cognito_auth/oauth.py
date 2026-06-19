"""CognitoOAuthExtension — serves OAuth metadata for MCP client discovery."""

import os
from typing import Any

from fastapi import APIRouter
from hindsight_api.extensions import HttpExtension


class CognitoOAuthExtension(HttpExtension):
    """Serves /.well-known/oauth-authorization-server for MCP OAuth discovery.

    OpenCode reads this endpoint to discover the Cognito authorization and token
    endpoints, then initiates a PKCE flow with the pre-registered client ID.

    Reads config from HINDSIGHT_API_TENANT_* env vars directly (shared with
    the TenantExtension) since the HTTP extension loader strips a different
    prefix (HINDSIGHT_API_HTTP_).
    """

    def __init__(self, config: dict[str, str]):
        super().__init__(config)

        self.issuer = os.environ.get("HINDSIGHT_API_TENANT_COGNITO_ISSUER")
        if not self.issuer:
            raise ValueError("HINDSIGHT_API_TENANT_COGNITO_ISSUER is required.")

        self.domain = os.environ.get("HINDSIGHT_API_TENANT_COGNITO_DOMAIN")
        if not self.domain:
            raise ValueError("HINDSIGHT_API_TENANT_COGNITO_DOMAIN is required.")

        self.client_id = os.environ.get("HINDSIGHT_API_TENANT_COGNITO_CLIENT_ID")
        if not self.client_id:
            raise ValueError("HINDSIGHT_API_TENANT_COGNITO_CLIENT_ID is required.")

    async def _oauth_metadata(self) -> dict[str, Any]:
        """Return the OAuth authorization server metadata document.

        Registered as the handler for /.well-known/oauth-authorization-server
        (see get_root_router). Defined as a method rather than a nested function
        so it is referenced explicitly at registration time.
        """
        return {
            "issuer": self.issuer,
            "authorization_endpoint": f"https://{self.domain}/oauth2/authorize",
            "token_endpoint": f"https://{self.domain}/oauth2/token",
            "response_types_supported": ["code"],
            "code_challenge_methods_supported": ["S256"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["openid", "email", "profile"],
        }

    def get_root_router(self, memory: Any) -> APIRouter:
        router = APIRouter()
        router.add_api_route(
            "/.well-known/oauth-authorization-server",
            self._oauth_metadata,
            methods=["GET"],
        )
        return router

    def get_router(self, memory: Any) -> APIRouter:
        return APIRouter()
