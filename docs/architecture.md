# Architecture

## Overview

[Hindsight](https://github.com/vectorize-io/hindsight) is a persistent memory system for AI agents, exposed over MCP (Model Context Protocol). Agents call `retain`, `recall`, and `reflect` tools to write conversation facts, retrieve relevant context, and synthesize reasoned answers from prior sessions. Memory is stored in PostgreSQL with `pgvector` for embeddings, file content lives in object storage, and inference (LLM, embeddings, reranker) is delegated to a configurable backend.

This sample deploys a self-hosted Hindsight reference stack on AWS: EKS Fargate hosts the Hindsight API, worker, and control plane pods; Aurora Serverless v2 provides PostgreSQL with `pgvector`; S3 backs file storage; and Bedrock provides all model calls. Authentication is handled by Cognito — OAuth 2.1 PKCE for MCP clients and OIDC at the ALB for the dashboard. A pair of Lambda functions implement a per-user API key system that gives plugins and scripts a stable token without each developer needing AWS credentials.

What makes this deployment notable: per-user `hsk_*` API keys rotated daily with a 24-hour grace window so plugins never break at the rotation boundary; a Cognito-only default that requires zero external infrastructure to bring up; and a bring-your-own-domain model where the only prerequisite is a Route 53 hosted zone you control. Federation with an external SAML or OIDC IdP is fully supported but optional — see `docs/federation.md` if you want to wire your existing identity provider into the Cognito user pool.

## Component diagram

The deployment runs three flows that share a few nodes (Cognito, the API pod,
Secrets Manager): the MCP request/inference path, on-demand API-key retrieval,
and the daily key rotation.

![Component diagram: client, ingress & identity, EKS workloads (Fargate or Auto Mode), storage, Bedrock, and the per-user API key lifecycle](diagrams/component-diagram.drawio.svg)

## Components

### EKS compute (Fargate by default, Auto Mode optional)
- Single namespace `hindsight`
- Three pods from one Helm release: `hindsight-api`, `hindsight-worker`, `hindsight-control-plane`
- One sidecar deployment: `litellm-proxy`
- IRSA for AWS access (no static credentials in pods)

### Aurora Serverless v2
- PostgreSQL 16.4 with `pgvector`
- Auto-scales (configurable min/max ACU; default 0.5–2)

### S3
- Single bucket for file storage
- Hindsight pods access via IRSA

### ALB + Ingress
- Two ingresses share one ALB via ingress group `hindsight`:
  - `<your-domain>` → API (port 8888)
  - `cp.<your-domain>` → Control Plane (port 3000), with ALB OIDC auth via Cognito
- TLS via ACM cert covering both hostnames

### Cognito
- One user pool with two app clients:
  - **MCP client** — public, PKCE-only, used by OpenCode/Claude Code OAuth flows
  - **ALB OIDC client** — confidential, used by ALB to gate browser sessions for the Control Plane dashboard
- Federation (SAML/OIDC IdP) is optional; see `docs/federation.md`

### LiteLLM proxy
- Sidecar deployment, port 4000
- Brokers Bedrock embeddings and reranker calls with SigV4 signing via IRSA
- See "Why LiteLLM proxy" below for the rationale

### Custom auth extension
- `CognitoTenantExtension` (Python) deployed to the API pod via ConfigMap + volume mount at `/app/hindsight_cognito_auth`
- Validates Cognito JWTs against JWKS and per-user API keys against an in-memory map
- Source: `infra/hindsight/extensions/hindsight_cognito_auth/`

### Per-user API key system
- **Rotation Lambda** (cron, daily 05:00 UTC) — lists Cognito users, generates a `hsk_*` key per user, stores both current + previous keys in Secrets Manager, syncs the key map to a K8s secret, then triggers a rolling restart of the API deployment.
- **Retrieval Lambda** (HTTP, behind API Gateway) — reads the user's identity from a Cognito-validated JWT and returns their current API key in the response body.
- API Gateway domain: `auth.<your-domain>` (separate from the main API)
- Both keys (current + previous) are valid for a 24-hour grace window during rotation, so users don't see breakage at the rotation boundary.

## Data flow

### MCP request path
1. Client opens browser, completes Cognito PKCE flow.
2. Client gets a Cognito access token (12-hour validity).
3. Client sends MCP request → ALB → API pod.
4. API pod's `CognitoTenantExtension` validates the JWT against Cognito's JWKS.
5. API pod processes retain/recall/reflect, persisting state to Aurora and reading/writing files in S3.

### Per-user API key path (plugins, scripts)
1. User runs `hindsight-auth.sh` → opens browser, completes Cognito PKCE flow.
2. Script exchanges code for access token.
3. Script calls `auth.<your-domain>/my-key` with the token in the Authorization header.
4. Get-Key Lambda validates the JWT, looks up the user's key from Secrets Manager.
5. Script caches `hsk_*` to `~/.hindsight/token` (mode 0600).
6. Plugins use the `hsk_*` directly with `Authorization: Bearer hsk_...` headers.

## Key design decisions

### Why per-user API keys (instead of relying on JWTs alone)

JWTs are great for interactive MCP sessions — short lifetime, refreshed automatically by the OAuth client — but the OAuth dance is awkward in non-interactive contexts like CI jobs, plugin background hooks, and small shell scripts. A stable per-user API key sidesteps that: each developer gets one `hsk_*` token tied to their Cognito identity, and revoking access is just disabling the user in the pool. No AWS credentials are needed on developer laptops. The 24-hour rotation grace window means a daily key rotation never breaks a plugin mid-session, since both the current and previous keys remain valid until the next rotation.

### Why LiteLLM proxy (instead of direct Bedrock)

Hindsight's `litellm-sdk` provider passes whatever value is in `api_key` as a Bearer token on outgoing HTTP calls, which clobbers the AWS SigV4 signing that Bedrock requires. Switching to the `litellm` (proxy) provider lets us configure the model with `api_key=None` so no Bearer header gets attached, and the proxy itself handles Bedrock auth using its own IRSA credentials. The proxy is a small, stateless deployment that adds one network hop but unlocks Bedrock SigV4 transparently for all Hindsight LLM, embeddings, and reranker calls.

### Why Fargate by default (and how to use Auto Mode)

Fargate removes node management entirely — no autoscaler tuning, no AMI patching, no draining nodes for upgrades — and bills per-pod, which fits a workload that scales modestly. The tradeoff is slow pod scheduling (~2 minutes for cold starts), which is why Helm uses a 600s timeout and probes use a 120s `initialDelaySeconds`. Fargate also has no GPU support, but that's a non-issue here because all inference is delegated to Bedrock. Fargate is the **default and the tested path** for this sample.

AWS now positions **EKS Auto Mode** as the recommended approach going forward, so it is available as an opt-in via `compute_mode = "auto"`. Auto Mode runs AWS-managed EC2 nodes (Karpenter-provisioned Bottlerocket) instead of Fargate, with faster pod scheduling and support for GPU/Spot and full Kubernetes conformance — advantages this small, Bedrock-delegated workload doesn't currently need, which is why Fargate remains the default.

Two deliberate choices keep the toggle small:

- **The self-managed AWS Load Balancer Controller is retained in both modes.** Auto Mode ships a built-in load balancer controller, but it does not support ALB OIDC authentication (`alb.ingress.kubernetes.io/auth-type: oidc`), which this stack uses to gate the Control Plane dashboard at the ALB. Keeping the self-managed controller preserves OIDC auth, the shared ingress group, and the `alb_drain` teardown logic unchanged.
- **IRSA is used for pod AWS access in both modes.** EKS Pod Identity is not supported on Fargate (its agent runs as a `hostNetwork` DaemonSet, which Fargate has no nodes for), so IRSA is the only credential mechanism that works uniformly across both compute modes. Pod Identity could be a future enhancement scoped to the Auto Mode path only.

The compute mode is chosen at cluster creation. Switching in place is not supported (disabling Auto Mode is a sticky, multi-step operation), so changing modes on an existing deployment effectively means recreating the cluster.

### Why Bedrock Rerank IAM needs `Resource: "*"`

`bedrock:InvokeModel` can be scoped to specific foundation model ARNs, but the Bedrock Rerank API does not accept any resource qualifier — the IAM policy must use `Resource: "*"`. This is an AWS Bedrock quirk, not a sample-specific choice. The IRSA role for the LiteLLM proxy reflects this: invoke and embedding actions are scoped to the model ARNs you actually use, while the rerank action is granted on `*`.

### Why one ALB for two hostnames

The AWS Load Balancer Controller's `alb.ingress.kubernetes.io/group.name` annotation lets multiple Ingress resources share a single ALB. This sample puts the API on `<your-domain>` and the Control Plane dashboard on `cp.<your-domain>` behind the same load balancer. This avoids paying for a second ALB and keeps the DNS/cert setup uniform — one ACM certificate covering both hostnames, one Route 53 alias record per hostname pointing at the same ALB.

### Why Cognito-only by default

Anyone who can run `terraform apply` against an AWS account can also run `aws cognito-idp create-user-pool`, so a plain Cognito pool is the lowest-friction default — no external IdP, no SAML metadata, no federation contracts. Adding the Route 53 hosted zone you already control gives you a working, multi-user deployment in a single `terraform apply`. If you want to plug an existing SAML or OIDC IdP into the pool (so users sign in with their company account instead of a Cognito-native one), `docs/federation.md` documents the additional resources and trust setup.

## Security boundaries

- IRSA for all pod → AWS access; no static credentials in K8s.
- Cognito JWTs verified against JWKS; signing keys cached in-memory for 10 minutes.
- API keys are 32-hex tokens stored in Secrets Manager and a K8s secret; rotated daily; previous key remains valid for a 24-hour grace window.
- ALB security group permits 443 from `0.0.0.0/0` because the Control Plane is gated by Cognito OIDC at the ALB and the API is gated by the in-pod auth extension. Optionally, a `my_ip` tfvar can additionally restrict to a specific CIDR for hardening.
- The state file is local (`*.tfstate` is in `.gitignore`). For team deployments, configure an S3 backend with state locking. This sample does not include an S3 backend by default.

## Repo structure

```
.
├── README.md, AGENTS.md, CLAUDE.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, LICENSE
├── docs/
│   ├── architecture.md  (you are here)
│   ├── deployment.md    (step-by-step deploy)
│   └── federation.md    (optional SAML/OIDC IdP add-on)
├── infra/hindsight/     (single flat Terraform root)
│   ├── *.tf
│   ├── extensions/      (custom Cognito auth extension, deployed as ConfigMap)
│   ├── lambda/          (rotate-api-keys, get-api-key, layers/)
│   └── values/          (Helm values overrides)
└── config/              (auth scripts and bank configuration tooling)
    ├── banks/           (personal.py, shared.py — bank definitions)
    ├── apply.py
    └── hindsight-auth.{sh,py}
```
