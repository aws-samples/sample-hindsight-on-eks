# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read [AGENTS.md](AGENTS.md) first — it contains project context, stack, layout, commands, architecture boundaries, key quirks, and conventions that apply here.

## Additional Context

### Data flow

```
MCP Client (OpenCode) → ALB (443) → Hindsight API (8888)
                                         ├── Aurora Serverless v2 (PostgreSQL + pgvector)
                                         ├── S3 (file storage)
                                         └── LiteLLM proxy (4000) → Bedrock (embeddings/reranker)
Browser → ALB (443, OIDC auth) → Control Plane (3000)
```

LLM calls go direct to Bedrock (native provider); embeddings/reranker route through LiteLLM proxy because Hindsight's litellm-sdk provider's Bearer token overwrites SigV4 signing.

### Auth extension internals

Python files in `extensions/hindsight_cognito_auth/`:
- `tenant.py` — JWT validation via JWKS, bank access check (`_check_bank_access`: currently permissive — allows every bank, and only runs on `/mcp/...` paths), alias extraction from IdP claims
- `oauth.py` — serves OAuth discovery for MCP clients: `/.well-known/oauth-protected-resource` (RFC 9728, names Cognito as the authorization server) and the legacy `/.well-known/oauth-authorization-server`. Requires `HINDSIGHT_API_TENANT_PUBLIC_URL`, which `tenant.py` also uses for the `resource_metadata` link in 401 challenges

### Validation

There are no linters, test suites, or build steps beyond `terraform validate`. Verify changes with `terraform plan` from `infra/hindsight/`.
