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
export HINDSIGHT_BANK_ID=$(whoami)

# Cognito auth (used by hindsight-auth.sh — values from `terraform output`)
export HINDSIGHT_COGNITO_DOMAIN="<cognito-domain-prefix>.auth.<region>.amazoncognito.com"
export HINDSIGHT_COGNITO_CLIENT_ID="<from-terraform-output-mcp_client_id>"
export HINDSIGHT_KEY_ENDPOINT="https://auth.<your-domain>/my-key"

# API key (cached by hindsight-auth.sh after first auth)
export HINDSIGHT_API_TOKEN=$(cat ~/.hindsight/token 2>/dev/null)
```

## Daily Auth (run once per day)

```bash
# MCP servers (for opencode/claude code)
opencode mcp auth hindsight
opencode mcp auth hindsight-shared

# API key (for plugins and config script)
./config/hindsight-auth.sh
```

Then restart your shell or `source ~/.zshrc`.

## Applying Bank Config

```bash
cd config
./setup-venv.sh            # first time only — installs hindsight-client from PyPI
source venv/bin/activate
python apply.py personal   # configure your personal bank
python apply.py shared     # configure the shared bank
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

## Plugins (Auto-Retain + Auto-Recall)

In addition to the MCP servers (which provide explicit retain/recall/reflect tools), you can install plugins that automatically capture conversations and inject recalled context.

**OpenCode**: Add `@vectorize-io/opencode-hindsight` to `~/.config/opencode/opencode.json` plugin array.

**Claude Code**: `claude plugin marketplace add vectorize-io/hindsight && claude plugin install hindsight-memory`, configure at `~/.hindsight/claude-code.json`.

Both read `HINDSIGHT_API_URL`, `HINDSIGHT_API_TOKEN`, and `HINDSIGHT_BANK_ID` from the environment.

See the main [README](../README.md#plugins-auto-retain--auto-recall) for full configuration details.

## How API Keys Work

- Keys are generated daily at 05:00 UTC from Cognito user pool membership
- Each user gets a unique `hsk_...` key
- Both current and previous keys are valid (24h grace period)
- Key retrieval uses the same Cognito PKCE flow as MCP auth
- Keys are stored at `~/.hindsight/token` (mode 0600)

## Architecture

```
[Cognito] -> [Rotation Lambda] -> [Secrets Manager] + [K8s Secret]
                                          |
[hindsight-auth.sh] -> [API Gateway] -> [Get-API-Key Lambda] -> reads secret
                            |
                    JWT Authorizer (Cognito)
```
