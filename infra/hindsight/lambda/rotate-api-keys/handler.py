"""Rotation Lambda: generates per-user API keys from Cognito pool membership.

Reads users from Cognito, generates keys, updates Secrets Manager and K8s.
"""

import json
import os
import re
import secrets
import base64
import datetime

import boto3
import kubernetes
from kubernetes import client as k8s_client


def handler(event, context):
    """Secrets Manager rotation handler.

    Supports the four rotation steps: createSecret, setSecret, testSecret, finishSecret.
    We implement all logic in finishSecret for simplicity (single-secret rotation).
    """
    step = event.get("Step", "finishSecret")
    secret_id = event.get("SecretId", os.environ.get("SECRET_ID"))

    if step in ("createSecret", "setSecret", "testSecret"):
        # No-op for intermediate steps — we do everything in finishSecret
        return

    # finishSecret: full rotation
    cognito = boto3.client("cognito-idp")
    sm = boto3.client("secretsmanager")

    # 1. List users from Cognito
    aliases = _list_cognito_aliases(cognito)

    # 2. Load current secret
    current = _get_current_secret(sm, secret_id)

    # 3. Rotate: move current keys to previous, generate new keys
    previous_by_key = current.get("by_key", {})
    new_by_user = {}
    new_by_key = {}

    for alias in aliases:
        key = _generate_key()
        new_by_user[alias] = key
        new_by_key[key] = alias

    new_secret = {
        "by_user": new_by_user,
        "by_key": new_by_key,
        "previous_by_key": previous_by_key,
    }

    # 4. Write updated secret
    sm.put_secret_value(
        SecretId=secret_id,
        SecretString=json.dumps(new_secret),
        VersionStages=["AWSCURRENT"],
    )

    # 5. Update K8s secret and restart pods
    _update_k8s_secret(new_secret)

    print(f"Rotation complete. Users: {list(new_by_user.keys())}")


def _list_cognito_aliases(cognito):
    """List all enabled users from Cognito and extract aliases."""
    user_pool_id = os.environ["COGNITO_USER_POOL_ID"]
    # Empty default = no IdP prefix to strip (Cognito-only deployment).
    # Set COGNITO_IDP_PREFIX to e.g. "MyIdP_" when SAML/OIDC federation is configured.
    idp_prefix = os.environ.get("COGNITO_IDP_PREFIX", "")

    aliases = []
    paginator = cognito.get_paginator("list_users")

    for page in paginator.paginate(UserPoolId=user_pool_id):
        for user in page["Users"]:
            if not user.get("Enabled", True):
                continue
            username = user["Username"]
            alias = _extract_alias(username, idp_prefix)
            if alias:
                aliases.append(alias)

    return aliases


def _extract_alias(username, idp_prefix):
    """Extract and sanitize alias from Cognito username.

    Same logic as CognitoTenantExtension._extract_alias() in tenant.py.
    """
    if username.startswith(idp_prefix):
        alias = username[len(idp_prefix):]
    else:
        alias = username

    # Sanitize: lowercase, only [a-zA-Z0-9_-]
    alias = re.sub(r"[^a-zA-Z0-9_-]", "", alias).lower()
    return alias if alias else None


def _generate_key():
    """Generate a random API key with hsk_ prefix."""
    return f"hsk_{secrets.token_hex(16)}"


def _get_current_secret(sm, secret_id):
    """Load the current secret value, or empty structure if new."""
    try:
        response = sm.get_secret_value(SecretId=secret_id)
        return json.loads(response["SecretString"])
    except sm.exceptions.ResourceNotFoundException:
        return {"by_user": {}, "by_key": {}, "previous_by_key": {}}


def _update_k8s_secret(secret_data):
    """Update the K8s secret in the hindsight namespace and restart pods."""
    namespace = os.environ.get("K8S_NAMESPACE", "hindsight")
    secret_name = os.environ.get("K8S_SECRET_NAME", "hindsight-api-keys")
    cluster_name = os.environ["EKS_CLUSTER_NAME"]
    region = os.environ.get("AWS_REGION", "us-east-1")

    # Authenticate to EKS using IAM
    eks = boto3.client("eks", region_name=region)
    cluster_info = eks.describe_cluster(name=cluster_name)["cluster"]

    # Configure kubernetes client
    configuration = kubernetes.client.Configuration()
    configuration.host = cluster_info["endpoint"]
    configuration.verify_ssl = True
    configuration.ssl_ca_cert = "/tmp/ca.crt"

    # Write CA cert
    ca_data = base64.b64decode(cluster_info["certificateAuthority"]["data"])
    with open("/tmp/ca.crt", "wb") as f:
        f.write(ca_data)

    # Get bearer token via presigned STS URL and attach it directly as the
    # Authorization header. NOTE: configuration.api_key={"authorization": ...}
    # does NOT work here — the kubernetes client keys bearer auth under the
    # security-scheme name "BearerToken", not "authorization", so that form
    # sends the request anonymously (apiserver sees user:{}, returns 401).
    # Setting the default header is version-independent and unambiguous.
    token = _get_eks_token(cluster_name, region)
    api_client = kubernetes.client.ApiClient(configuration)
    api_client.set_default_header("Authorization", "Bearer " + token)
    v1 = kubernetes.client.CoreV1Api(api_client)
    apps_v1 = kubernetes.client.AppsV1Api(api_client)

    # Prepare the key map for the tenant extension (by_key + previous_by_key only)
    tenant_keys_json = json.dumps({
        "by_key": secret_data["by_key"],
        "previous_by_key": secret_data["previous_by_key"],
    })

    # Update or create the K8s secret
    secret_body = kubernetes.client.V1Secret(
        metadata=kubernetes.client.V1ObjectMeta(name=secret_name, namespace=namespace),
        string_data={"HINDSIGHT_API_TENANT_USER_API_KEYS": tenant_keys_json},
    )

    try:
        v1.replace_namespaced_secret(name=secret_name, namespace=namespace, body=secret_body)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 404:
            v1.create_namespaced_secret(namespace=namespace, body=secret_body)
        else:
            raise

    # Trigger rolling restart of API deployment
    now = datetime.datetime.utcnow().isoformat() + "Z"
    patch_body = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {"hindsight-eks/restartedAt": now}
                }
            }
        }
    }

    try:
        apps_v1.patch_namespaced_deployment(
            name="hindsight-api", namespace=namespace, body=patch_body
        )
    except kubernetes.client.exceptions.ApiException:
        # Deployment name might differ — try the Helm release name
        apps_v1.patch_namespaced_deployment(
            name="hindsight", namespace=namespace, body=patch_body
        )


def _get_eks_token(cluster_name, region):
    """Generate a presigned-URL bearer token for EKS authentication.

    Mirrors what `aws eks get-token` does: presign an STS GetCallerIdentity
    request whose `x-k8s-aws-id` header is part of the SigV4 signature, then
    base64url-encode it with the `k8s-aws-v1.` prefix. The header MUST be signed
    (registered via a before-sign event handler) or EKS rejects the token 401.
    """
    import botocore.session

    session = botocore.session.get_session()
    client = session.create_client("sts", region_name=region)

    # Register the cluster-name header so it is included in the signed headers.
    def _add_header(request, **kwargs):
        request.headers["x-k8s-aws-id"] = cluster_name

    client.meta.events.register(
        "before-sign.sts.GetCallerIdentity", _add_header
    )

    signed_url = client.generate_presigned_url(
        "get_caller_identity",
        Params={},
        ExpiresIn=60,
        HttpMethod="GET",
    )

    return "k8s-aws-v1." + base64.urlsafe_b64encode(
        signed_url.encode("utf-8")
    ).decode("utf-8").rstrip("=")
