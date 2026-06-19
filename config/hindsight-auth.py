#!/usr/bin/env python3
"""Hindsight API key retrieval via Cognito PKCE flow.

Opens a browser for Cognito authentication (federated to your IdP if configured),
receives the authorization code, exchanges it for an access token, then fetches
the user's API key from the key-retrieval endpoint. Caches the key to
~/.hindsight/token.

Required environment variables:
    HINDSIGHT_COGNITO_DOMAIN     - e.g. mypool.auth.us-west-2.amazoncognito.com
    HINDSIGHT_COGNITO_CLIENT_ID  - Cognito MCP app client ID
    HINDSIGHT_KEY_ENDPOINT       - e.g. https://auth.<your-domain>/my-key

Optional:
    HINDSIGHT_AUTH_CALLBACK_PORT - defaults to 19876
"""

import hashlib
import base64
import http.server
import json
import os
import secrets
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser

# --- Configuration ---
# All endpoints and identifiers are loaded from environment variables.
# Use `terraform output` from infra/hindsight to retrieve the values.
COGNITO_DOMAIN = os.environ.get("HINDSIGHT_COGNITO_DOMAIN", "")
CLIENT_ID = os.environ.get("HINDSIGHT_COGNITO_CLIENT_ID", "")
CALLBACK_PORT_RAW = os.environ.get("HINDSIGHT_AUTH_CALLBACK_PORT", "19876")
KEY_ENDPOINT = os.environ.get("HINDSIGHT_KEY_ENDPOINT", "")
TOKEN_FILE = os.path.expanduser("~/.hindsight/token")
SCOPES = "openid email profile"

# Populated by _check_required_env() once CALLBACK_PORT_RAW is validated.
CALLBACK_PORT = 0
CALLBACK_URL = ""


def _check_required_env():
    """Verify required environment variables are set; print friendly errors otherwise."""
    global CALLBACK_PORT, CALLBACK_URL
    errors = []
    if not COGNITO_DOMAIN:
        errors.append("HINDSIGHT_COGNITO_DOMAIN is not set")
    if not CLIENT_ID:
        errors.append("HINDSIGHT_COGNITO_CLIENT_ID is not set")
    if not KEY_ENDPOINT:
        errors.append("HINDSIGHT_KEY_ENDPOINT is not set")
    try:
        CALLBACK_PORT = int(CALLBACK_PORT_RAW)
    except ValueError:
        errors.append(f"HINDSIGHT_AUTH_CALLBACK_PORT must be an integer (got {CALLBACK_PORT_RAW!r})")

    if errors:
        print("Error: invalid environment configuration:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        print("\nRetrieve values from your Terraform deployment:", file=sys.stderr)
        print("  cd infra/hindsight && terraform output", file=sys.stderr)
        sys.exit(1)

    CALLBACK_URL = f"http://localhost:{CALLBACK_PORT}/callback"


def main():
    print("Authenticating to Hindsight...")
    _check_required_env()

    # Generate PKCE parameters
    code_verifier = secrets.token_urlsafe(32)
    code_challenge = base64.urlsafe_b64encode(
        hashlib.sha256(code_verifier.encode()).digest()
    ).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)

    # Start local callback server
    auth_result = {"code": None, "error": None}
    server = _start_callback_server(state, auth_result)

    # Build authorize URL and open browser
    params = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": CALLBACK_URL,
        "scope": SCOPES,
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    })
    authorize_url = f"https://{COGNITO_DOMAIN}/oauth2/authorize?{params}"

    print("Opening browser for authentication...")
    webbrowser.open(authorize_url)
    print("Waiting for browser callback (timeout: 120s)...")

    # Wait for callback
    server.handle_request()
    server.server_close()

    if auth_result["error"]:
        print(f"Authentication failed: {auth_result['error']}", file=sys.stderr)
        sys.exit(1)

    if not auth_result["code"]:
        print("No authorization code received", file=sys.stderr)
        sys.exit(1)

    # Exchange code for access token
    print("Exchanging code for token...")
    access_token = _exchange_code(auth_result["code"], code_verifier)

    # Fetch API key from retrieval endpoint
    print("Fetching API key...")
    api_key = _fetch_api_key(access_token)

    # Write to file
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    with open(TOKEN_FILE, "w") as f:
        f.write(api_key)
    os.chmod(TOKEN_FILE, 0o600)

    print(f"API key cached to {TOKEN_FILE}")
    print(f"  Valid until next rotation (~24 hours)")
    print(f"  Restart your shell or run: export HINDSIGHT_API_TOKEN=$(cat {TOKEN_FILE})")


def _start_callback_server(expected_state, result):
    """Start a local HTTP server to receive the OAuth callback."""

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            state = params.get("state", [None])[0]

            if state != expected_state:
                result["error"] = "State mismatch"
            elif "error" in params:
                result["error"] = params["error"][0]
            else:
                result["code"] = params.get("code", [None])[0]

            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            if result["code"]:
                self.wfile.write(
                    b"<html><body><h2>Authentication successful!</h2>"
                    b"<p>You can close this tab.</p></body></html>"
                )
            else:
                self.wfile.write(
                    b"<html><body><h2>Authentication failed.</h2></body></html>"
                )

        def log_message(self, format, *args):
            pass  # Suppress HTTP request logs

    server = http.server.HTTPServer(("localhost", CALLBACK_PORT), CallbackHandler)
    server.timeout = 120
    return server


def _require_https(url):
    """Reject non-HTTPS URLs before opening them.

    Guards against urllib.request.urlopen following unexpected schemes such as
    file:// or custom schemes (Bandit B310). All Hindsight endpoints are HTTPS.
    """
    scheme = urllib.parse.urlparse(url).scheme
    if scheme != "https":
        print(f"Refusing to open non-HTTPS URL (scheme={scheme!r}): {url}", file=sys.stderr)
        sys.exit(1)
    return url


def _exchange_code(code, code_verifier):
    """Exchange authorization code for access token."""
    token_url = _require_https(f"https://{COGNITO_DOMAIN}/oauth2/token")
    data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": code,
        "redirect_uri": CALLBACK_URL,
        "code_verifier": code_verifier,
    }).encode()

    req = urllib.request.Request(
        token_url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    try:
        with urllib.request.urlopen(req) as resp:  # nosec B310 (URL scheme validated by _require_https)
            tokens = json.loads(resp.read())
            return tokens["access_token"]
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"Token exchange failed: {e.code} {body}", file=sys.stderr)
        sys.exit(1)


def _fetch_api_key(access_token):
    """Fetch the user's API key from the retrieval endpoint."""
    req = urllib.request.Request(
        _require_https(KEY_ENDPOINT),
        headers={"Authorization": f"Bearer {access_token}"},
    )

    try:
        with urllib.request.urlopen(req) as resp:  # nosec B310 (URL scheme validated by _require_https)
            return resp.read().decode().strip()
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 404:
            print("Your user is not provisioned yet. Wait for rotation or contact admin.", file=sys.stderr)
        else:
            print(f"Key retrieval failed: {e.code} {body}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
