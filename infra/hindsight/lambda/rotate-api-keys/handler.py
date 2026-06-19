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

    # Get bearer token via presigned STS URL
    token = _get_eks_token(cluster_name, region)
    configuration.api_key = {"authorization": token}
    configuration.api_key_prefix = {"authorization": "Bearer"}

    api_client = kubernetes.client.ApiClient(configuration)
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
    """Generate a presigned URL token for EKS authentication (same as aws eks get-token).

    Uses the STS presigned GetCallerIdentity URL approach that EKS expects.
    """
    import botocore.session
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest

    session = botocore.session.get_session()
    credentials = session.get_credentials().get_frozen_credentials()

    # Build the STS GetCallerIdentity request
    sts_url = f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15"

    # Create the request with the required x-k8s-aws-id header
    request = AWSRequest(method="GET", url=sts_url, headers={"x-k8s-aws-id": cluster_name})

    # Sign it with SigV4
    SigV4Auth(credentials, "sts", region).add_auth(request)

    # Build the signed URL from the request (include auth in query string instead of headers)
    # We need to use presigned URL format — rebuild with query params
    from botocore.auth import HmacV1Auth
    from urllib.parse import urlencode, quote

    # Alternative: use generate_presigned_url via the STS client
    sts_client = boto3.client("sts", region_name=region)

    # Use the low-level botocore presigner
    from botocore.signers import RequestSigner

    service_model = sts_client._service_model
    signer = RequestSigner(
        service_model.service_id,
        region,
        "sts",
        "v4",
        session.get_credentials(),
        session.get_component("event_emitter"),
    )

    # Generate presigned URL for GetCallerIdentity
    signed_url = signer.generate_presigned_url(
        {
            "method": "GET",
            "url": f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
            "body": {},
            "headers": {"x-k8s-aws-id": cluster_name},
            "context": {},
        },
        region_name=region,
        expires_in=60,
        operation_name="",
    )

    return "k8s-aws-v1." + base64.urlsafe_b64encode(signed_url.encode("utf-8")).decode("utf-8").rstrip("=")
