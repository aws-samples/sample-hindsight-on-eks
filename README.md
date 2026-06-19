# sample-hindsight-on-eks

A reference deployment of [Hindsight](https://github.com/vectorize-io/hindsight) — a self-hosted persistent memory system for AI agents — on AWS EKS Fargate, with Aurora Serverless v2 + pgvector, S3, Bedrock-backed LLM and embeddings, and Cognito authentication.

> **Disclaimer:** This is sample code for educational purposes and is not intended for production use without security review. Costs incurred from deploying this sample are your responsibility. Review the IAM policies, security groups, and Cognito configuration against your organization's standards before deploying.

## What this deploys

- **EKS Fargate** running the Hindsight API, worker, and Control Plane pods
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

Deployment takes ~10 minutes (Fargate pod scheduling is slow).

## Authentication

Hindsight supports two authentication methods:

| Method | Used by | Token lifetime | How to authenticate |
|--------|---------|---------------|---------------------|
| **OAuth2/PKCE (JWT)** | MCP servers (OpenCode, Claude Code) | 12 hours | `opencode mcp auth hindsight` |
| **Per-user API key** | Config scripts, plugins, direct API calls | 24 hours (rotated daily at 05:00 UTC) | `./config/hindsight-auth.sh` |

Both methods authenticate via Cognito/your IdP in the browser. The difference is what you get back: MCP tools use short-lived JWTs directly, while the API key flow exchanges a JWT for a stable `hsk_*` key that works across tools.

### Daily Auth Routine

Run once per day (or when you see "Token expired" errors):

```bash
# 1. MCP servers (for opencode/claude code interactive sessions)
opencode mcp auth hindsight
opencode mcp auth hindsight-shared

# 2. API key (for config scripts, plugins, and direct API calls)
./config/hindsight-auth.sh
```

The auth script opens a browser for Cognito sign-in, fetches your personal API key from `auth.<your-domain>/my-key`, and caches it to `~/.hindsight/token` (mode 0600). It uses only the Python standard library — no venv or pip install required.

### Shell Environment

Add to your `~/.zshrc`:

```bash
# Hindsight API key (cached by hindsight-auth.sh)
export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token 2>/dev/null)
export HINDSIGHT_API_URL="https://<your-domain>"
export HINDSIGHT_BANK_ID=$(whoami)
```

Then restart your shell or `source ~/.zshrc` after running the auth script.

### How API Keys Work

- A Lambda runs daily at 05:00 UTC, listing all enabled Cognito users
- Each user gets a unique `hsk_<32-hex-chars>` key
- Both current and previous keys are valid (24-hour grace period during rotation)
- Keys are stored in AWS Secrets Manager and synced to a K8s secret
- The tenant extension validates keys by lookup (O(1) hash map, no network call)
- No AWS credentials needed on developer laptops — just the cached `hsk_*` key

## Configuring MCP Servers

### OpenCode

After deployment, get the MCP config:

```bash
cd infra/hindsight
terraform output opencode_mcp_config
```

Add the output to your `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "hindsight": {
      "type": "remote",
      "url": "https://<your-domain>/mcp/<your-alias>/",
      "oauth": {
        "clientId": "<mcp_client_id>",
        "scope": "openid email profile"
      }
    },
    "hindsight-shared": {
      "type": "remote",
      "url": "https://<your-domain>/mcp/shared/",
      "oauth": {
        "clientId": "<mcp_client_id>",
        "scope": "openid email profile"
      }
    }
  }
}
```

OpenCode handles the PKCE flow automatically — on first use it opens a browser for Cognito login, then caches the tokens.

Before your first session, authenticate each MCP server:

```bash
opencode mcp auth hindsight
opencode mcp auth hindsight-shared
```

### Claude Code

Add the MCP servers using the CLI:

```bash
# Shared team bank (--scope user writes to ~/.claude.json)
claude mcp add --transport http hindsight-shared \
  https://<your-domain>/mcp/shared/ \
  --client-id <mcp_client_id> \
  --callback-port 19876 \
  --scope user

# Personal bank
claude mcp add --transport http hindsight \
  https://<your-domain>/mcp/<your-alias>/ \
  --client-id <mcp_client_id> \
  --callback-port 19876 \
  --scope user
```

Then inside a Claude Code session, run `/mcp` to list your MCP servers and authenticate if needed.

## Plugins (Auto-Retain + Auto-Recall)

The MCP servers above give the agent explicit retain/recall/reflect tools. The **plugins** go further — they automatically capture conversations and inject recalled context on every prompt, with no agent action required.

Both plugins use the per-user API key (`hsk_*`) for authentication.

### OpenCode Plugin

Add to your global `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    ["@vectorize-io/opencode-hindsight", {
      "hindsightApiUrl": "https://<your-domain>",
      "hindsightApiToken": "<your hsk_* key>",
      "bankId": "<your-alias>",
      "autoRecall": true,
      "autoRetain": true,
      "recallBudget": "mid",
      "retainEveryNTurns": 3
    }]
  ]
}
```

Or use environment variables (reads from `~/.hindsight/token` if `HINDSIGHT_API_TOKEN` is set):

```bash
export HINDSIGHT_API_URL="https://<your-domain>"
export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token)
export HINDSIGHT_BANK_ID=$(whoami)
```

The plugin auto-installs on startup — no `npm install` needed.

**What it does:**
- **Auto-recall** — on session start, queries your bank and injects relevant memories into the system prompt
- **Auto-retain** — when the session goes idle, captures the conversation transcript to Hindsight
- **Compaction hook** — retains memories before context window compaction so they survive trimming
- **Explicit tools** — `hindsight_retain`, `hindsight_recall`, `hindsight_reflect` available for direct agent use

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `retainEveryNTurns` | `3` | Retain every N turns (higher = fewer API calls) |
| `recallBudget` | `"mid"` | `low`/`mid`/`high` — controls recall depth vs latency |
| `autoRecall` | `true` | Inject recalled memories on session start |
| `autoRetain` | `true` | Auto-capture conversations |

Persistent config can also live at `~/.hindsight/opencode.json` (applies across all projects).

Full docs: https://hindsight.vectorize.io/sdks/integrations/opencode

### Claude Code Plugin

Install from the Hindsight marketplace:

```bash
claude plugin marketplace add vectorize-io/hindsight
claude plugin install hindsight-memory
```

Configure at `~/.hindsight/claude-code.json`:

```json
{
  "hindsightApiUrl": "https://<your-domain>",
  "hindsightApiToken": "<your hsk_* key>",
  "bankId": "<your-alias>",
  "autoRecall": true,
  "autoRetain": true,
  "recallBudget": "mid",
  "retainEveryNTurns": 10,
  "enableKnowledgeTools": true
}
```

Or via environment variables (same as OpenCode — reads `HINDSIGHT_API_URL`, `HINDSIGHT_API_TOKEN`, `HINDSIGHT_BANK_ID`).

**What it does:**
- **Auto-recall** — on every user prompt, queries Hindsight and injects memories as invisible `additionalContext`
- **Auto-retain** — after every N turns, extracts and retains the conversation transcript
- **Knowledge tools** — `agent_knowledge_*` MCP tools for explicit read/write/search of memory pages
- **Subagent skill** — `/hindsight-memory:create-agent` scaffolds a subagent backed by an isolated memory bank

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `retainEveryNTurns` | `10` | Retain every N turns (higher than OpenCode's default of 3 because Claude Code includes a 2-turn overlap window per chunk, so each retain sends 12 turns of transcript) |
| `recallBudget` | `"mid"` | `low`/`mid`/`high` |
| `recallMaxTokens` | `1024` | Max tokens in recalled memory block |
| `enableKnowledgeTools` | `false` | Expose `agent_knowledge_*` MCP tools |
| `dynamicBankId` | `false` | Derive bank ID from agent+project context |
| `resolveWorktrees` | `true` | All worktrees of same repo share one bank |

Full docs: https://hindsight.vectorize.io/sdks/integrations/claude-code

### MCP Servers vs Plugins

| | MCP Servers | Plugins |
|--|-------------|---------|
| **Auth** | OAuth PKCE (JWT) | API key (`hsk_*`) |
| **Auto-retain** | No — agent must call `retain` explicitly | Yes — captures conversations automatically |
| **Auto-recall** | No — agent must call `recall` explicitly | Yes — injects on session/prompt start |
| **Shared bank** | Yes (`hindsight-shared` server) | Not built-in (use MCP server for shared) |
| **Setup** | `opencode mcp auth` / `claude mcp add` | Plugin config + env vars |

**Recommended setup:** Use both. The plugin handles your personal bank automatically (auto-retain + auto-recall), while the MCP shared server gives the agent access to team knowledge via explicit `hindsight-shared_recall`.

## Bank Configuration

Bank settings (missions, directives, mental models, entity labels) are version-controlled in `config/banks/` and applied idempotently via `config/apply.py`.

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

## How Memory Operations Work

The MCP server exposes three core tools that the LLM invokes based on natural language context — no special keywords required:

| Tool | Triggered when... | Example prompts |
|------|-------------------|-----------------|
| **retain** | User shares facts, preferences, decisions, or project details | "Remember that...", "We decided to use...", "My preference is..." |
| **recall** | Agent needs context from previous sessions | "What do you know about...", "Have I mentioned...", start of conversation |
| **reflect** | Reasoned analysis needed, not just fact retrieval | "What should I do about...", "Based on past decisions..." |

The agent decides autonomously when to call each tool. You can also add rules to your `AGENTS.md` to guide behavior (e.g., "Always recall at the start of a conversation").

### Targeting Personal vs Shared Banks

OpenCode prefixes each MCP server's tools with the server name from your config. With the recommended naming:

| You say... | Agent uses | Bank |
|------------|-----------|------|
| "Remember this for me" | `hindsight_retain` | personal (`/mcp/<your-alias>/`) |
| "Store this as team knowledge" | `hindsight-shared_retain` | shared (`/mcp/shared/`) |
| "What do I know about X?" | `hindsight_recall` | personal |
| "What does the team know about X?" | `hindsight-shared_recall` | shared |

### Verifying the Connection

After running `opencode mcp auth`, start a session and try:

- **Retain**: "Remember that hindsight was deployed on May 5th"
- **Recall**: "What do you know about the hindsight deployment?"
- **Reflect**: "Based on what you know, what should I focus on next?"

If auth has expired, you'll see a "Token expired" error — re-run `opencode mcp auth hindsight` and restart the session.

## Structure

```
.
├── config/
│   ├── hindsight-auth.sh   # PKCE auth script (fetches API key)
│   ├── hindsight-auth.py   # Auth implementation (stdlib only)
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
│       ├── outputs.tf      # API URL, OpenCode MCP config
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
- [Hindsight MCP server docs](https://hindsight.vectorize.io/developer/mcp-server)
- [OpenCode MCP server docs](https://opencode.ai/docs/mcp-servers/)
- [Model Context Protocol](https://modelcontextprotocol.io)

## Security

If you discover a potential security issue in this sample, please notify AWS Security via [aws-security@amazon.com](mailto:aws-security@amazon.com). Please do **not** create a public GitHub issue.

## License

This sample is licensed under the MIT-0 License. See [LICENSE](LICENSE).
