# Hindsight Configuration

Scripts for managing Hindsight memory bank configuration and authentication.

## Prerequisites

- Python 3.10+ (auth script uses stdlib only — no venv needed)
- For `apply.py`: a Python venv with `hindsight-client` installed via `./setup-venv.sh` (see below)
- Hindsight environment variables exported (see Daily Setup)

## Daily Setup

After running `terraform apply`, retrieve your deployment's auth endpoints:

```bash
cd infra/hindsight
terraform output
```

Add the values to your `~/.zshrc` (substitute `<your-domain>` with `var.hindsight_domain`):

```bash
# Hindsight API endpoint
export HINDSIGHT_API_URL="https://<your-domain>"

# Cognito auth (used by hindsight-auth.sh — values from `terraform output`)
export HINDSIGHT_COGNITO_DOMAIN="<cognito-domain-prefix>.auth.<region>.amazoncognito.com"
export HINDSIGHT_COGNITO_CLIENT_ID="<from-terraform-output-mcp_client_id>"
export HINDSIGHT_KEY_ENDPOINT="https://auth.<your-domain>/my-key"

# API key (cached by hindsight-auth.sh after first auth)
export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token 2>/dev/null)
```

Don't export `HINDSIGHT_BANK_ID`. It pins the coding-agents plugin to one bank and turns off the per-repo `project-<repo>` banks.

## Daily Auth (run once per day)

```bash
./config/hindsight-auth.sh
```

This caches the key to `~/.hindsight/token` and also writes it into `~/.hindsight/coding-agent.json` (if that file exists), so a running coding-agents plugin picks up the rotated key without a restart. Restart your shell or `source ~/.zshrc` to refresh `HINDSIGHT_API_TOKEN` for scripts.

If you also use the optional MCP servers, re-authenticate them when their 12-hour tokens expire: `opencode mcp auth <server>`.

## Applying Bank Config

```bash
cd config
./setup-venv.sh            # first time only — installs hindsight-client from PyPI
source venv/bin/activate
python apply.py personal   # configure your personal bank (optional, used over MCP)
python apply.py shared     # configure the shared bank (optional, used over MCP)
```

Options:
- `--dry-run` — show what would change without applying
- `--force` — delete extra directives without prompting
- `--alias NAME` — override the alias (default: `whoami`)
- `--list` — show available bank configurations

## Editing Bank Config

Bank definitions are in `config/banks/`:
- `personal.py` — missions, dispositions, entity labels, directives, mental models
- `shared.py` — same structure for the team shared bank

Edit these files and re-run `python apply.py <bank>` to update.

## Memory Plugin

Coding agents use the `@vectorize-io/hindsight-coding-agents` plugin: one `project-<repo>` bank per repository, with settings in `~/.hindsight/coding-agent.json` (template: `terraform output -raw coding_agent_config`). The `personal` and `shared` bank definitions above are for optional banks you reach over MCP.

See the main [README](../README.md#memory-client-hindsight-coding-agents-plugin) for install and configuration.

## How API Keys Work

- Keys are generated daily at 05:00 UTC from Cognito user pool membership
- Each user gets a unique `hsk_...` key
- Both current and previous keys are valid (24h grace period)
- Key retrieval uses a Cognito PKCE flow (the same one MCP auth uses)
- Keys are stored at `~/.hindsight/token` (mode 0600)

## Architecture

```
[Cognito] -> [Rotation Lambda] -> [Secrets Manager] + [K8s Secret]
                                          |
[hindsight-auth.sh] -> [API Gateway] -> [Get-API-Key Lambda] -> reads secret
                            |
                    JWT Authorizer (Cognito)
```
