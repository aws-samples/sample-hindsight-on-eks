"""Key-retrieval Lambda: returns the caller's API key from Secrets Manager.

JWT validation is handled by API Gateway Cognito authorizer.
This Lambda only extracts the alias and looks up the key.
"""

import json
import os
import re
import boto3


sm = boto3.client("secretsmanager")
SECRET_ID = os.environ["SECRET_ID"]
# Empty default = no IdP prefix to strip (Cognito-only deployment).
# Set COGNITO_IDP_PREFIX to e.g. "MyIdP_" when SAML/OIDC federation is configured.
IDP_PREFIX = os.environ.get("COGNITO_IDP_PREFIX", "")

# Cache the secret for the Lambda execution context (up to ~15 min)
_cached_secret = None


def handler(event, context):
    """API Gateway Lambda proxy handler."""
    global _cached_secret

    # Extract claims from API Gateway JWT authorizer
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )

    if not claims:
        return _response(401, "No JWT claims found")

    # Extract alias from username claim
    username = claims.get("username", claims.get("cognito:username", ""))
    alias = _extract_alias(username)

    if not alias:
        return _response(400, "Could not determine user alias from token")

    # Fetch secret (with caching)
    secret = _get_secret()
    key = secret.get("by_user", {}).get(alias)

    if not key:
        return _response(404, f"No API key found for user: {alias}")

    return _response(200, key)


def _extract_alias(username):
    """Extract and sanitize alias from Cognito username."""
    if username.startswith(IDP_PREFIX):
        alias = username[len(IDP_PREFIX):]
    else:
        alias = username

    alias = re.sub(r"[^a-zA-Z0-9_-]", "", alias).lower()
    return alias if alias else None


def _get_secret():
    """Get secret with simple in-memory caching."""
    global _cached_secret
    if _cached_secret is None:
        response = sm.get_secret_value(SecretId=SECRET_ID)
        _cached_secret = json.loads(response["SecretString"])
    return _cached_secret


def _response(status_code, body):
    """Format API Gateway proxy response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "text/plain"},
        "body": body,
    }
