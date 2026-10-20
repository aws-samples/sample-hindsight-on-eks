"""CognitoOAuthExtension — serves OAuth discovery metadata for MCP clients."""

import os
from typing import Any

from fastapi import APIRouter
from hindsight_api.extensions import HttpExtension

PROTECTED_RESOURCE_PATH = "/.well-known/oauth-protected-resource"


def protected_resource_metadata_url(public_url: str) -> str:
    """URL of the RFC 9728 document, as advertised in WWW-Authenticate challenges."""
    return f"{public_url.rstrip('/')}{PROTECTED_RESOURCE_PATH}"


class CognitoOAuthExtension(HttpExtension):
    """Serves OAuth discovery documents so MCP clients can find Cognito.

    - /.well-known/oauth-protected-resource (RFC 9728) names Cognito as the
      authorization server. MCP clients follow it to Cognito's own discovery
      document, whose issuer matches — required by clients that enforce
      RFC 8414 §3.3, such as OpenCode 2.x.
    - /.well-known/oauth-authorization-server is the legacy document that older
      clients read from this host directly. Its issuer is Cognito, not this host,
      so strict clients reject it; it is kept for backward compatibility.

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

        # Public base URL MCP clients use to reach this server (e.g.
        # https://hindsight.example.com). Required: the protected resource
        # document must name the exact resource clients connect to, and the
        # Host header cannot be trusted to build it.
        self.public_url = os.environ.get("HINDSIGHT_API_TENANT_PUBLIC_URL", "").rstrip("/")
        if not self.public_url:
            raise ValueError("HINDSIGHT_API_TENANT_PUBLIC_URL is required.")

    async def _oauth_metadata(self) -> dict[str, Any]:
        """Return the legacy OAuth authorization server metadata document.

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

    async def _protected_resource_metadata(self) -> dict[str, Any]:
        """Return the RFC 9728 protected resource metadata document.

        The resource is the server origin, which covers every /mcp/{bank}/ path,
        so one document serves all banks.
        """
        return {
            "resource": self.public_url,
            "authorization_servers": [self.issuer],
            "bearer_methods_supported": ["header"],
            "scopes_supported": ["openid", "email", "profile"],
        }

    def get_root_router(self, memory: Any) -> APIRouter:
        router = APIRouter()
        router.add_api_route(
            "/.well-known/oauth-authorization-server",
            self._oauth_metadata,
            methods=["GET"],
        )
        # Clients try the path-specific form first (e.g.
        # /.well-known/oauth-protected-resource/mcp/<alias>/) and fall back to the
        # root form; both return the same document.
        router.add_api_route(PROTECTED_RESOURCE_PATH, self._protected_resource_metadata, methods=["GET"])
        router.add_api_route(
            PROTECTED_RESOURCE_PATH + "/{resource_path:path}",
            self._protected_resource_metadata,
            methods=["GET"],
        )
        return router

    def get_router(self, memory: Any) -> APIRouter:
        return APIRouter()
