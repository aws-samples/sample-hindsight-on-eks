# sample-hindsight-on-eks

A reference deployment of [Hindsight](https://github.com/vectorize-io/hindsight) — a self-hosted persistent memory system for AI agents — on AWS EKS (Fargate by default, EKS Auto Mode optional), with Aurora Serverless v2 + pgvector, S3, Bedrock-backed LLM and embeddings, and Cognito authentication.

> **Disclaimer:** This is sample code for educational purposes and is not intended for production use without security review. Costs incurred from deploying this sample are your responsibility. Review the IAM policies, security groups, and Cognito configuration against your organization's standards before deploying.

## What this deploys

- **EKS** running the Hindsight API, worker, and Control Plane pods — on **Fargate** by default, or **EKS Auto Mode** via `compute_mode = "auto"`
- **Aurora Serverless v2 (PostgreSQL + pgvector)** for memory storage, scales to near-zero when idle
- **S3** bucket for file uploads
- **Application Load Balancer** with two hostnames (API + dashboard) and TLS via ACM
- **Cognito** user pool for authentication (PKCE for MCP clients, OIDC for the dashboard)
- **Bedrock** as the LLM, embeddings, and reranker provider, brokered through a LiteLLM proxy for SigV4 auth
- **Per-user API key system** — Lambda-based daily key rotation with Secrets Manager + K8s secret sync

For a deeper walkthrough of components and design decisions, see [`docs/architecture.md`](docs/architecture.md).
For step-by-step deployment, see [`docs/deployment.md`](docs/deployment.md).
For optional SAML/OIDC federation setup, see [`docs/federation.md`](docs/federation.md).

## Prerequisites

- AWS CLI configured with appropriate credentials (`aws configure`)
- Terraform >= 1.5.0
- kubectl
- Python 3 (for auth scripts — no pip packages required)
- A Cognito User Pool with an identity provider configured (e.g., your IdP)
- A Route 53 hosted zone for your domain
- An AWS account with Bedrock model access enabled for:
  - `amazon.titan-embed-text-v2:0`
  - `cohere.rerank-v3-5:0`
  - Your chosen LLM model (e.g., `openai.gpt-oss-120b-1:0`)

## Deploying the Infrastructure

```bash
cd infra/hindsight
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

Deployment takes ~10 minutes (Fargate pod scheduling is slow). To deploy on EKS Auto Mode instead, set `compute_mode = "auto"` in `terraform.tfvars` before the first apply — the mode is chosen at cluster creation and cannot be switched in place.

## Authentication

Hindsight supports two authentication methods:

| Method | Used by | Token lifetime | How to authenticate |
|--------|---------|---------------|---------------------|
| **Per-user API key** | The coding-agents plugin, config scripts, direct API calls | 24 hours (rotated daily at 05:00 UTC) | `./config/hindsight-auth.sh` |
| **OAuth2/PKCE (JWT)** | MCP clients (optional, see [MCP Servers (Optional)](#mcp-servers-optional)) | 12 hours | `opencode mcp auth <server>` |

Both methods sign in through Cognito (federated to your IdP if configured) in the browser. The API key flow swaps the JWT for a stable `hsk_*` key that works in any tool. The day-to-day setup only needs the API key.

### Daily Auth Routine

Run once per day (or when memory calls start returning 401):

```bash
./config/hindsight-auth.sh
```

The script needs the `HINDSIGHT_COGNITO_*` and `HINDSIGHT_KEY_ENDPOINT` environment variables (see [`config/README.md`](config/README.md)). It opens a browser for Cognito sign-in and fetches your personal API key from `auth.<your-domain>/my-key`. It saves the key in two places (both mode 0600):

- `~/.hindsight/token`, used by scripts and `HINDSIGHT_API_TOKEN`
- `apiToken` in `~/.hindsight/coding-agent.json`, but only if that file already exists

The second write is what keeps a long-running agent working. A background service such as `opencode serve` keeps the environment it started with, so `HINDSIGHT_API_TOKEN` goes stale after rotation. The plugin, though, re-reads `apiToken` from its config file whenever a request is rejected, so it picks up the new key without a restart.

The script uses only the Python standard library, so it needs no venv or `pip install`.

### Shell Environment

For scripts and direct API calls, add this to your `~/.zshrc`:

```bash
# Hindsight API key (cached by hindsight-auth.sh)
export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token 2>/dev/null)
export HINDSIGHT_API_URL="https://<your-domain>"
```

> **Do not export `HINDSIGHT_BANK_ID`.** The coding-agents plugin treats it as a fixed bank, so
> every repo ends up writing to that one bank instead of its own.

### How API Keys Work

- A Lambda runs daily at 05:00 UTC, listing all enabled Cognito users
- Each user gets a unique `hsk_<32-hex-chars>` key
- Both current and previous keys are valid (24-hour grace period during rotation)
- Keys are stored in AWS Secrets Manager and synced to a K8s secret
- The tenant extension validates keys by lookup (O(1) hash map, no network call)
- No AWS credentials needed on developer laptops — just the cached `hsk_*` key

## Memory Client: hindsight-coding-agents Plugin

Coding agents reach memory through upstream's
[`@vectorize-io/hindsight-coding-agents`](https://github.com/vectorize-io/hindsight/tree/main/hindsight-integrations/coding-agents)
plugin. It works with OpenCode (1.x and 2.x), Claude Code, Codex CLI, Cursor CLI and other agents,
and replaces the older per-agent `@vectorize-io/opencode-hindsight` and `hindsight-memory` plugins.
The old OpenCode plugin does not load on OpenCode 2.x.

### What it does

- **One bank per repo.** The bank is `project-<repo>`, where `<repo>` is the folder name of the
  main worktree. Worktrees of a repo share its bank, and every agent you use in that repo shares it too.
- **Seeds itself.** The first time a repo is opened, its bank is seeded from recent commits and a
  read-only survey of the codebase. Each session start then adds new commits and conversations in
  the background and keeps a set of knowledge pages up to date.
- **Injects memory automatically.** On a session's first prompt it adds memory to the context. By
  default that's a short `reflect` synthesis over the bank. The agent doesn't need to call a tool.
- **Writes back.** Session transcripts are retained into the bank automatically.
- **Tools.** The agent also gets `hindsight_search_knowledge_pages`, `hindsight_read_knowledge_page`,
  `hindsight_reflect`, `hindsight_ingest_document`, `hindsight_capture_initiative` and
  `hindsight_diagnose`. On OpenCode they are native tools; on hook-based agents they come from
  a local MCP server that the installer registers.

### Configure

All settings live in one file, `~/.hindsight/coding-agent.json`. Terraform prints a template:

```bash
cd infra/hindsight
mkdir -p ~/.hindsight
terraform output -raw coding_agent_config | python3 -m json.tool > ~/.hindsight/coding-agent.json
chmod 600 ~/.hindsight/coding-agent.json
cd ../..
./config/hindsight-auth.sh   # fills in apiToken
```

The result looks like this:

```json
{
  "serverMode": "self-hosted",
  "apiUrl": "https://<your-domain>",
  "apiToken": "<your hsk_* key>",
  "bankIdTemplate": "project-{gitProject}",
  "dynamicBankId": true
}
```

| Field | Why it's set this way |
|-------|-----------------------|
| `serverMode: self-hosted` | Use this deployment rather than Hindsight Cloud or a local daemon |
| `apiToken` | Written by `hindsight-auth.sh` on every run. Don't edit it by hand. |
| `bankIdTemplate: project-{gitProject}` | Upstream's default is `coding-agent::{gitProject}`. The `project-` prefix matches the shared-bank naming in the auth extension (`tenant.py`). |
| `dynamicBankId: true` | Resolve the bank per repo, not as one fixed bank |

Other settings worth knowing about (the defaults are fine to start with):

| Field | Default | Notes |
|-------|---------|-------|
| `autoInject` | `"reflect"` | What gets injected on the first prompt: `reflect`, `pages`, `recall` or `none` |
| `reflectBudget` | `"high"` | Budget for the `hindsight_reflect` tool: `low`, `mid` or `high` |
| `codebaseSurvey` | `true` | The first time a repo is opened, a read-only survey runs through an agent CLI, which costs tokens. Set `false` to skip it. |
| `retainSessions` | `true` | Write session transcripts back to the bank |
| `autoUpdate` | `true` | Once a day, re-downloads a newer plugin runtime into `~/.hindsight/coding-agents`. It never edits your agent's config. |

The old plugins' settings (`autoRecall`, `autoRetain`, `recallBudget`, `retainEveryNTurns`,
`hindsightApiUrl`, `hindsightApiToken`, …) are not read by this plugin. The full settings reference is
in the [plugin README](https://github.com/vectorize-io/hindsight/tree/main/hindsight-integrations/coding-agents).

### Install

Pick the agent(s) to wire. `--server self-hosted` answers the installer's "where should memory
live" question up front:

```bash
npx @vectorize-io/hindsight-coding-agents install opencode2 --server self-hosted     # OpenCode 2.x
npx @vectorize-io/hindsight-coding-agents install opencode --server self-hosted      # OpenCode 1.x
npx @vectorize-io/hindsight-coding-agents install claude-code --server self-hosted   # Claude Code
npx @vectorize-io/hindsight-coding-agents install all --server self-hosted           # every agent it detects
```

The installer puts the runtime in `~/.hindsight/coding-agents` and wires each agent.

> **OpenCode 2.x:** the installer writes the 1.x `plugin` key. If your config uses the 2.x
> `plugins` list, move the entry there yourself and delete the `plugin` key, or the plugin
> loads twice:
>
> ```jsonc
> { "plugins": ["/Users/<you>/.hindsight/coding-agents"] }
> ```

Restart the agent afterwards. If OpenCode runs as a background service (`opencode service restart`),
start it from a shell that does **not** export `HINDSIGHT_BANK_ID`.

### Verify

In a session inside a git repo, ask the agent to run `hindsight_diagnose`. You should see:

- `bank_id: project-<repo>` (not a personal alias or the bank from `HINDSIGHT_BANK_ID`)
- `credential.api_token_in_use: true` and `api_token_matches_config: true`

If the bank is wrong, check the agent process's environment for a stale `HINDSIGHT_BANK_ID`.

### Caveats

- **Banks are named after the folder, not the remote.** Two unrelated repos checked out under
  the same folder name share a bank. If that matters, use `mapPathToBank` in the plugin config.
- **Bank listing isn't per-user.** All banks live in one schema, so `GET /v1/default/banks`
  shows every bank on the server.
- **Bank access isn't enforced yet.** `_check_bank_access` in the auth extension currently allows
  every bank, and it only runs on `/mcp/...` paths. Any authenticated user can reach any bank.

## MCP Servers (Optional)

The plugin covers day-to-day memory without MCP. MCP is still useful for reaching a specific bank
outside the current repo, such as a personal or team bank (see [Bank Configuration](#bank-configuration)).
The server exposes per-bank MCP endpoints with OAuth2/PKCE.

### OpenCode

```bash
cd infra/hindsight
terraform output opencode_mcp_config
```

That prints an `mcp` block for `opencode.json` with two remote servers: `hindsight`
(`https://<your-domain>/mcp/<your-alias>/`) and `hindsight-shared` (`https://<your-domain>/mcp/shared/`).
Each has `oauth.clientId`, `scope: "openid email profile"` and `callbackPort: 19876`. Replace
`<your-alias>` with your Cognito username, then authenticate each server once:

```bash
opencode mcp auth hindsight
opencode mcp auth hindsight-shared
```

OpenCode prefixes each server's tools with its name, so the agent sees `hindsight_recall` (personal)
and `hindsight-shared_recall` (team). If you also run the plugin, rename the personal server
(for example `hindsight-personal`): its `hindsight_reflect` tool would otherwise have the same name
as the plugin's.

### Claude Code

```bash
claude mcp add --transport http hindsight-shared https://<your-domain>/mcp/shared/ \
  --client-id <COGNITO_CLIENT_ID> --callback-port 19876 --scope user
claude mcp add --transport http hindsight-personal https://<your-domain>/mcp/<your-alias>/ \
  --client-id <COGNITO_CLIENT_ID> --callback-port 19876 --scope user
```

Then run `/mcp` inside a session to authenticate. `terraform output mcp_client_id` gives the client ID.

### Notes

- `callbackPort` keeps the local OAuth callback on a port Cognito accepts. OpenCode 2.x otherwise
  picks a random port, and Cognito rejects the login with `redirect_mismatch`.
- If auth fails with `Issuer mismatch in authorization server metadata (RFC 8414 §3.3)`, see
  [`docs/deployment.md`](docs/deployment.md#oauth-issuer-mismatch-in-authorization-server-metadata).
- MCP tools are only called when the agent decides to, so they recall far less than the plugin's
  automatic injection does.

## Bank Configuration

Bank settings (missions, directives, mental models, entity labels) are version-controlled in `config/banks/` and applied idempotently via `config/apply.py`.

> These definitions are for the optional personal (`<your-alias>`) and team (`shared`) banks, which
> you reach over [MCP](#mcp-servers-optional). The per-repo `project-*` banks are created and
> configured by the coding-agents plugin from its own bank manifest. `apply.py` doesn't manage them.

### First-Time Setup

```bash
cd config
./setup-venv.sh              # creates venv, installs hindsight-client
source venv/bin/activate
```

### Applying Configuration

```bash
# Ensure your API key is set
export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token)

# Apply your personal bank config
python apply.py personal

# Apply the shared team bank config
python apply.py shared
```

Options:
- `--dry-run` — show what would change without applying
- `--force` — delete extra directives without prompting
- `--alias NAME` — override the alias (default: `whoami`)
- `--list` — show available bank configurations

### Editing Bank Config

Bank definitions are in `config/banks/`:

| File | Bank ID | Purpose |
|------|---------|---------|
| `personal.py` | `<your-alias>` | Individual memory: preferences, decisions, project context |
| `shared.py` | `shared` | Team knowledge: standards, architecture decisions, runbooks |

Each file defines:
- **CONFIG** — missions, dispositions, entity labels, extraction mode
- **DIRECTIVES** — rules the memory engine follows (e.g., "never store secrets")
- **MENTAL_MODELS** — living summaries that auto-refresh (e.g., "Current Projects")

Edit these files and re-run `python apply.py <bank>` to update.

## Dashboard (Control Plane)

The control plane provides a web UI for browsing memory banks, entities, documents, and testing recall queries interactively.

Access it directly via the ALB (authenticates through Cognito/your IdP):

```
https://cp.<your-domain>
```

## Structure

```
.
├── config/
│   ├── hindsight-auth.sh   # PKCE auth script (fetches API key)
│   ├── hindsight-auth.py   # Auth implementation (stdlib only; also updates coding-agent.json)
│   ├── apply.py            # Bank configuration script
│   ├── setup-venv.sh       # Virtual env setup for apply.py
│   ├── requirements.txt    # Python deps (hindsight-client>=0.7.2 from PyPI)
│   └── banks/
│       ├── personal.py     # Personal bank definition
│       └── shared.py       # Shared bank definition
├── infra/
│   └── hindsight/          # Terraform root module
│       ├── main.tf         # Providers, locals, data sources
│       ├── vpc.tf          # VPC, subnets, NAT
│       ├── eks.tf          # EKS Fargate cluster, CoreDNS addon
│       ├── rds.tf          # Aurora Serverless v2 PostgreSQL
│       ├── s3.tf           # S3 bucket, IAM policies (S3 + Bedrock)
│       ├── alb.tf          # AWS Load Balancer Controller
│       ├── auth.tf         # Cognito app clients (MCP + ALB OIDC)
│       ├── dns.tf          # ACM certificate, Route 53 records
│       ├── hindsight.tf    # Hindsight Helm release, IRSA, K8s secret
│       ├── api-keys.tf     # Secrets Manager, rotation Lambda, EKS access
│       ├── api-keys-gateway.tf  # API Gateway for key retrieval
│       ├── litellm-proxy.tf # LiteLLM proxy (Bedrock auth via IRSA)
│       ├── outputs.tf      # API URL, coding-agent.json template, OpenCode MCP config
│       ├── variables.tf
│       ├── extensions/
│       │   └── hindsight_cognito_auth/  # Custom Python auth extension
│       ├── lambda/
│       │   ├── rotate-api-keys/   # Daily key rotation (Cognito -> keys)
│       │   ├── get-api-key/       # Key retrieval (JWT -> user's key)
│       │   └── layers/            # Lambda layer build scripts
│       └── values/
│           └── hindsight.yaml  # Helm values override
└── docs/
    ├── architecture.md     # System overview and design decisions
    ├── deployment.md       # Step-by-step deploy walkthrough
    └── federation.md       # Optional SAML/OIDC IdP add-on
```

## Teardown

```bash
cd infra/hindsight
terraform destroy
```

## Related

- [Hindsight upstream](https://github.com/vectorize-io/hindsight) — source code, Helm chart, docs
- [Hindsight documentation](https://hindsight.vectorize.io)
- [hindsight-coding-agents plugin](https://github.com/vectorize-io/hindsight/tree/main/hindsight-integrations/coding-agents)
- [Hindsight MCP server docs](https://hindsight.vectorize.io/developer/mcp-server)
- [OpenCode MCP server docs](https://opencode.ai/docs/mcp-servers/)
- [Model Context Protocol](https://modelcontextprotocol.io)

## Security

If you discover a potential security issue in this sample, please notify AWS Security via [aws-security@amazon.com](mailto:aws-security@amazon.com). Please do **not** create a public GitHub issue.

## License

This sample is licensed under the MIT-0 License. See [LICENSE](LICENSE).
