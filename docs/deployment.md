# Deployment

This walkthrough takes a fresh AWS account from zero to a working Hindsight deployment in approximately 20 minutes (10 minutes of `terraform apply` time).

The **default** path is fully self-contained: Terraform creates a sample Cognito user pool for you, and you reach the deployment over `kubectl port-forward`. **No public domain and no pre-existing Cognito pool are required.** Two optional paths — [going public](#going-public-optional) and [bringing your own Cognito pool / IdP](#bring-your-own-cognito-pool--idp-optional) — are covered after the main walkthrough.

## Prerequisites

- AWS account with admin-level credentials (an IAM role with `AdministratorAccess` is sufficient for the initial apply; you can scope it down afterward).
- AWS CLI configured: `aws configure --profile <your-profile>`
- Terraform >= 1.5.0
- `kubectl` >= 1.28
- macOS or Linux (the sample's helper scripts assume Bash; Windows users can use WSL2).

You do **not** need:

- A public domain or Route 53 hosted zone — only required for the optional [public endpoint](#going-public-optional).
- A pre-existing Cognito user pool — Terraform creates one by default (`create_identity_provider = true`).
- A manual Bedrock "model access" step — serverless foundation models auto-enable on first invocation (the model-access console page has been retired). The default model `openai.gpt-oss-120b-1:0` needs no manual opt-in. (Some Anthropic models may ask first-time users to submit use-case details, and Marketplace models require one initial invocation, but the default OpenAI OSS model just works.)

## Step 1: Configure tfvars

```bash
cd infra/hindsight
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set just three values for the self-contained path:

| Variable | What to set it to |
|---|---|
| `aws_region` | The region where you want resources (e.g., `us-east-1`). Must support Bedrock. |
| `aws_profile` | Your AWS CLI profile name (admin-level for the first apply). |
| `db_password` | A strong random value: `openssl rand -base64 24`. Save this somewhere — Terraform won't show it again. |

`bedrock_model_id` defaults to `openai.gpt-oss-120b-1:0` and can be left as-is. Leave the optional `public_endpoint`, bring-your-own-pool, and `federation` blocks commented out for now.

## Step 2: Build the Lambda layer (automatic)

The `rotate-api-keys` Lambda includes a Kubernetes Python client packaged as a Lambda layer. Terraform builds this layer automatically during `plan`/`apply` by running `lambda/layers/build-kubernetes-layer.sh` (it produces `.build/kubernetes-layer.zip`, which is gitignored).

You normally don't need to do anything here. If you'd like to build it ahead of time (e.g., to inspect the artifact or pre-warm the build), run:

```bash
cd infra/hindsight
bash lambda/layers/build-kubernetes-layer.sh
```

## Step 3: Apply Terraform

```bash
cd infra/hindsight
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Expected:
- `terraform init` downloads providers (one-time, ~2 minutes).
- `terraform plan` reports ~50–60 resources to add. Review for surprises.
- `terraform apply` takes 8–12 minutes. Most time is spent on Aurora cluster creation (~5 minutes), EKS cluster creation (~3 minutes), and Fargate pod scheduling (~2 minutes per pod).

If apply fails partway through (rare but possible), `terraform apply` again is safe and idempotent.

## Step 4: Configure kubectl

```bash
aws eks update-kubeconfig \
  --name $(terraform -chdir=infra/hindsight output -raw eks_cluster_name) \
  --profile <your-profile> \
  --region <your-region>

kubectl get pods -n hindsight
```

This writes credentials to `~/.kube/config` (the default location). If you need to use a non-default kubeconfig path, set `KUBECONFIG` in your environment before running `terraform apply` so that subsequent `kubectl patch` calls during the apply find the right cluster.

Expected: `hindsight-api`, `hindsight-worker`, `hindsight-control-plane`, and `litellm-proxy` pods all `Running`. Initial scheduling can take 2 minutes per pod on Fargate; if any pod is `Pending` for longer than 5 minutes, `kubectl describe pod -n hindsight <pod>` will show why (commonly: insufficient subnet capacity or wrong subnet tags).

### Deploying on EKS Auto Mode (optional)

By default this sample runs on Fargate, which is the validated path. To use EKS Auto Mode instead, set `compute_mode = "auto"` in `terraform.tfvars` before the first `terraform apply`. The mode is chosen at cluster creation; switching an existing cluster between modes is not supported and requires recreating it.

In Auto Mode the cluster runs AWS-managed EC2 nodes instead of Fargate. After apply, smoke-test the Auto Mode path:

```sh
# Pods should land on EC2 instances (node names start with "i-"), not "fargate-*".
kubectl get pods -n hindsight -o wide

# Confirm the managed node pools exist and are Ready.
kubectl get nodepool

# Confirm the ALB/ingress still came up (the self-managed LB controller runs in both modes).
kubectl get ingress -n hindsight

# Confirm the dashboard still enforces Cognito OIDC: browsing to cp.<your-domain>
# should redirect to the Cognito hosted UI before the Control Plane loads.
```

Auto Mode is less battle-tested in this sample than the Fargate default — treat it as an opt-in and verify the four smoke-test items above before relying on it.

## Step 5: Port-forward the API and Control Plane

In the self-contained (internal) deployment the ALB is internal-only, so you reach the services through `kubectl port-forward`. Terraform emits ready-to-paste commands:

```bash
cd infra/hindsight
terraform output port_forward_commands
```

This prints the two commands to run (each in its own terminal):

```bash
kubectl port-forward -n hindsight svc/hindsight-api 8888:8888
kubectl port-forward -n hindsight svc/hindsight-control-plane 3000:3000
```

While the port-forwards are running:
- The API is at `http://localhost:8888` (see the `hindsight_api_url` output, which reports the localhost URL in internal mode).
- The Control Plane dashboard is at `http://localhost:3000` (see the `control_plane_url` output).

## Step 6: Create a Cognito user

Terraform created a sample user pool. Create a user in it and set a permanent password:

```bash
cd infra/hindsight
POOL_ID=$(terraform output -raw cognito_user_pool_id)

aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username you@example.com \
  --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS \
  --profile <your-profile> \
  --region <your-region>

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username you@example.com \
  --password 'ChangeMeStrongPassword1!' \
  --permanent \
  --profile <your-profile> \
  --region <your-region>
```

The Cognito hosted-UI domain for this pool is available via:

```bash
terraform output -raw cognito_hosted_ui_domain
```

## Step 7: Mint a per-user API key

The per-user API key is provisioned during the daily 05:00 UTC rotation. If you just created the Cognito user, you don't need to wait — invoke the rotation Lambda manually:

```bash
aws lambda invoke \
  --function-name hindsight-rotate-api-keys \
  --profile <your-profile> \
  --region <your-region> \
  /tmp/rotate-output.json
cat /tmp/rotate-output.json
```

After rotation, your `hsk_*` key is synced into the deployment and available to the auth flow. Both the current and previous keys remain valid during a grace period, so a re-rotation won't immediately invalidate an existing key.

## Step 8: Smoke test

With the API port-forward from Step 5 still running:

```bash
curl -s http://localhost:8888/health
```

Expected: `{"status":"ok"}` or similar.

You can also browse the Control Plane dashboard at `http://localhost:3000` (Control Plane port-forward must be running).

## Step 9: Connect MCP clients

Get the OpenCode MCP config snippet (it emits `localhost` URLs in internal mode):

```bash
cd infra/hindsight
terraform output opencode_mcp_config
```

Add the output to your `~/.config/opencode/opencode.json` (or a project-level `opencode.json`), then authenticate each MCP server:

```bash
opencode mcp auth hindsight
opencode mcp auth hindsight-shared
```

For Claude Code, add the servers with the localhost URLs from the output and run `/mcp` inside a session to authenticate.

## Step 10: Initialize bank configurations

```bash
cd config
./setup-venv.sh
source venv/bin/activate
python apply.py personal
python apply.py shared
```

Expected: each command prints "Done!" after creating/updating the bank profile, directives, and mental models. See `config/banks/personal.py` and `config/banks/shared.py` for the bank definitions.

## Going public (optional)

To expose Hindsight on the public internet with TLS, set the following in `terraform.tfvars` and re-apply:

```hcl
public_endpoint  = true
hosted_zone_id   = "Z0123456789ABCDEF"      # aws route53 list-hosted-zones
hindsight_domain = "hindsight.example.com"
```

```bash
cd infra/hindsight
terraform plan -out=tfplan
terraform apply tfplan
```

Setting `public_endpoint = true` provisions:

- **ACM certificates**, DNS-validated automatically via Route 53 records in your hosted zone. ACM validation can take a few minutes — `terraform apply` waits for it.
- An **internet-facing ALB** in place of the internal one.
- The **Control Plane behind Cognito OIDC** at `cp.<hindsight_domain>`.
- The **API custom domain** at your `hindsight_domain`, with the auth endpoint at `auth.<hindsight_domain>`.

In public mode the `hindsight_api_url`, `control_plane_url`, and `opencode_mcp_config` outputs report the public HTTPS URLs instead of localhost, and `kubectl port-forward` is no longer required for normal use.

## Bring your own Cognito pool / IdP (optional)

To use an existing Cognito user pool instead of letting Terraform create one, set:

```hcl
create_identity_provider = false
cognito_user_pool_id     = "us-east-1_xxxxxxxxx"
cognito_domain_prefix    = "my-hindsight-pool"
# cognito_idp_name       = "MyCorpIdP"   # only if the pool already federates to a SAML/OIDC IdP
```

When `create_identity_provider = false`, Terraform references your pool by ID and does not manage it. If your existing pool federates to a SAML or OIDC IdP, set `cognito_idp_name` to the IdP's `provider_name` so the per-user key Lambdas strip the `<provider_name>_` username prefix correctly.

If you instead want Terraform to create the pool **and** attach your corporate IdP, leave `create_identity_provider = true` and use the `federation` variable — see [federation.md](federation.md).

## Teardown

```bash
cd infra/hindsight
terraform destroy
```

Notes:
- The S3 bucket may need manual emptying if Hindsight stored files. Force-empty: `aws s3 rm s3://<bucket-name> --recursive`.
- Secrets Manager retains deleted secrets for 7 days by default. To shorten, add `--force-delete-without-recovery` when destroying via CLI.
- If you used `create_identity_provider = false`, `terraform destroy` does NOT delete your pre-existing Cognito user pool (it's only referenced by ID, not managed). Delete it manually if no longer needed: `aws cognito-idp delete-user-pool --user-pool-id <pool-id>`. When Terraform created the pool (the default), `terraform destroy` removes it.
- Teardown automatically drains the shared ALB first (a destroy-time step deletes the ingresses and waits for the AWS Load Balancer Controller to remove the ALB before the controller itself is torn down). If that step is interrupted or times out, see "terraform destroy hangs on an ingress / orphaned ALB" below.

## Troubleshooting

### Pods stuck `Pending` longer than 5 minutes

Fargate scheduling is slow but not THAT slow. Run:

```bash
kubectl describe pod -n hindsight <pod-name>
```

Common causes:
- Subnet missing the required tag `kubernetes.io/role/elb=1` — Terraform tags the public subnets but if you've imported existing subnets, verify.
- Insufficient subnet IP capacity — each Fargate pod consumes one IP. Use larger subnets or add additional ones.
- Fargate profile selector mismatch — ensure the namespace `hindsight` is included in the `selectors` of the Fargate profile.

### OAuth "redirect_uri_mismatch" error

Confirm the callback URLs in the Cognito MCP app client match what your client uses. Default callback URLs supported by this sample:
- `http://localhost:19876/callback`
- `http://localhost:19876/mcp/oauth/callback`
- `http://localhost:8080/callback`

If your client uses a different port, add it to `aws_cognito_user_pool_client.hindsight_mcp.callback_urls` in `auth.tf` and re-apply.

If you've changed the callback port, also set `HINDSIGHT_AUTH_CALLBACK_PORT` in your environment so the auth helper script uses the matching port:

```bash
export HINDSIGHT_AUTH_CALLBACK_PORT=8080  # or whatever you chose
```

### `bedrock:Rerank AccessDenied`

Bedrock Rerank uses a serverless model that enables on first invocation. If you see a persistent `AccessDenied` for `cohere.rerank-v3-5:0`, confirm your IAM role/IRSA policy grants `bedrock:Rerank` (the sample scopes this to `Resource: "*"`, which Rerank requires) and that the model is available in your region.

### Worker pod `CrashLoopBackOff`

Most often a `HINDSIGHT_API_PORT` collision. The Helm values explicitly set the worker's port to `8889` to avoid the K8s service-injection issue. If you've customized values, verify:

```bash
kubectl get deployment -n hindsight hindsight-worker -o yaml | grep HINDSIGHT_API_PORT
```
Should show `value: "8889"`.

### `terraform apply` fails building the Kubernetes Lambda layer

Terraform runs `lambda/layers/build-kubernetes-layer.sh` during apply, which calls `pip3`. If this fails, check that `python3`, `pip3`, and `zip` are installed and that you have network access to PyPI. You can run the script manually (see Step 2) to see the full error.

### API key endpoint returns 404 ("Your user is not provisioned yet")

The rotation Lambda runs daily at 05:00 UTC. After creating a new Cognito user, either wait for the next rotation or invoke the Lambda manually (see Step 7).

### `terraform destroy` hangs on an ingress / orphaned ALB

Both ingresses share one ALB via the ingress group, and the ALB's lifecycle is managed by the AWS Load Balancer Controller through a finalizer (`group.ingress.k8s.aws/hindsight`). If the controller stops reconciling during teardown (for example it loses leader election while its Fargate pods are being recycled), the ingresses get stuck `Terminating`, the finalizer is never cleared, and the ALB is orphaned. `terraform destroy` then fails with `Ingress (hindsight/...) still exists`.

The deployment includes an automatic destroy-time drain step (`null_resource.alb_drain`) that deletes the ingresses and waits for the ALB to be removed *before* the controller is torn down, which prevents this in the normal case. If you still hit a hang (interrupted destroy, controller already gone, etc.), recover manually:

```bash
# 1. Point kubectl at the cluster (if not already configured)
aws eks update-kubeconfig --name <project_name>-cluster --region <your-region> --profile <your-profile>

# 2. Delete the orphaned ALB directly (find its ARN first)
aws elbv2 describe-load-balancers --region <your-region> \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-hindsight')].LoadBalancerArn" --output text
aws elbv2 delete-load-balancer --region <your-region> --load-balancer-arn <arn>

# 3. Force-remove the stuck finalizers so the ingresses can delete
kubectl patch ingress <name> -n hindsight -p '{"metadata":{"finalizers":[]}}' --type=merge

# 4. Re-run terraform destroy
terraform destroy
```

If the EKS cluster itself is already gone but `kubernetes_*` resources remain in state, remove them from state so destroy can finish: `terraform state rm kubernetes_namespace.hindsight` (and any other unreachable `kubernetes_*` entries), then `terraform destroy` again.
