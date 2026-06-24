# AGENTS.md

## Project

Self-hosted [Hindsight](https://github.com/vectorize-io/hindsight) (persistent AI agent memory via MCP) on AWS EKS — Fargate by default, EKS Auto Mode optional. Infrastructure-only repo — no application code, no tests, no CI.

## Stack

Terraform → EKS (Fargate or Auto Mode) → Aurora Serverless v2 (PostgreSQL 16.4 + pgvector) + S3 + Bedrock (via LiteLLM proxy) + Cognito (auth) + ALB + Route 53

## Layout

```
infra/hindsight/          # Terraform root module — all infra lives here
  extensions/             # Custom Python auth extension (deployed via ConfigMap)
  lambda/                 # Lambda functions (key rotation, key retrieval)
  values/                 # Helm values overrides
config/                   # Auth scripts, bank config (apply.py), bank definitions
  banks/                  # Bank definitions (personal.py, shared.py)
docs/                     # architecture.md, deployment.md, federation.md
```

## Commands

All Terraform commands run from `infra/hindsight/`:

```sh
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output opencode_mcp_config   # MCP config snippet for opencode.json
```

Kubernetes access:
```sh
aws eks update-kubeconfig --name $(terraform -chdir=infra/hindsight output -raw eks_cluster_name) --profile <your-profile> --region <your-region>
kubectl port-forward -n hindsight svc/hindsight-control-plane 3000:3000
```

## Architecture Boundaries

- Single namespace: `hindsight` on Fargate
- Two ingresses share one ALB (ingress group `hindsight`):
  - `hindsight.example.com` → API (port 8888)
  - `cp.hindsight.example.com` → Control Plane (port 3000)
- LiteLLM proxy (port 4000) brokers Bedrock calls with SigV4 via IRSA — needed because Hindsight's litellm-sdk provider's Bearer token overwrites SigV4 signing
- Auth: Cognito with two app clients (public PKCE for MCP, confidential for ALB OIDC → your IdP)
- Extensions are Python source deployed via ConfigMap + volume mount at `/app/hindsight_cognito_auth`

## Key Quirks

- **No remote backend** — Terraform state is local (gitignored). Don't look for S3 backend config.
- **No CI/CD** — all deploys are manual `terraform apply`.
- **No automated tests** — validation is `terraform validate` + manual smoke tests.
- **Worker port conflict** — K8s service injection clobbers `HINDSIGHT_API_PORT`; worker env must explicitly set port `8889`.
- **Fargate pod scheduling is slow** (~2 min). Helm timeout is 600s, probes have 120s initialDelay.
- **Cognito access tokens lack `aud` claim** — extension validates `client_id` claim instead (`verify_aud: False`).
- **Bedrock Rerank IAM** needs `Resource: "*"` (can't scope to model ARNs).
- **AWS profile** — set in `terraform.tfvars` (no default; required).
- **`.terraform.lock.hcl` is gitignored** — intentional choice.
- **hindsight-client SDK** — installed from PyPI via `config/setup-venv.sh` (`hindsight-client>=0.7.2`).
- **Per-user API keys** — rotated daily at 05:00 UTC by Lambda; both current and previous keys valid (grace period). Keys synced to K8s secret via rotation Lambda's EKS access.
- **Compute mode is set at creation** — `compute_mode = "fargate"` (default) or `"auto"` (EKS Auto Mode). Switching in place is unsupported: disabling Auto Mode requires an explicit `enabled = false` apply before the block can be removed, so changing modes on a live cluster effectively means recreating it.
- **Self-managed LB controller is kept in Auto Mode** — Auto Mode's built-in load balancer controller cannot do ALB OIDC auth (which gates the dashboard), so the Helm `aws-load-balancer-controller` is deployed in both modes.
- **IRSA everywhere (not Pod Identity)** — Pod Identity is unsupported on Fargate (hostNetwork DaemonSet), so IRSA is used in both modes to keep AWS access identical across the toggle.

## Conventions

- Commit style: `feat(infra):`, `fix(auth):`, `docs:`, `style(infra):`
- All IaC in one flat Terraform module (no child modules) — files are split by concern (vpc, eks, rds, alb, etc.)
- IRSA for all AWS access from pods — no static credentials anywhere
- See `docs/architecture.md` for system context before non-trivial changes

## When Modifying the Auth Extension

The Python files in `infra/hindsight/extensions/hindsight_cognito_auth/` are loaded into Terraform via `file()` and deployed as a ConfigMap. After editing:
1. Run `terraform plan` — you'll see the ConfigMap data change
2. Apply — pods need restart to pick up the new mount content
