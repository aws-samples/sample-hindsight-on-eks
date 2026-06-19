# Per-user API keys for Hindsight plugins and tooling auth

data "aws_caller_identity" "current" {}

# --- Secrets Manager Secret ---

resource "aws_secretsmanager_secret" "hindsight_api_keys" {
  name        = "hindsight/api-keys"
  description = "Per-user Hindsight API keys (rotated daily by Lambda)"
  kms_key_id  = aws_kms_key.hindsight.arn
  tags        = local.tags
}

# Seed the secret with an empty structure (rotation Lambda populates it)
resource "aws_secretsmanager_secret_version" "hindsight_api_keys_initial" {
  secret_id = aws_secretsmanager_secret.hindsight_api_keys.id
  secret_string = jsonencode({
    by_user         = {}
    by_key          = {}
    previous_by_key = {}
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# --- Lambda Packaging ---

data "archive_file" "rotate_api_keys" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/rotate-api-keys"
  output_path = "${path.module}/.build/rotate-api-keys.zip"
}

# --- Lambda Layer (kubernetes Python client) ---

# Build the layer's site-packages via pip (platform-specific wheels that
# archive_file alone cannot produce). Re-runs when the build script changes.
resource "null_resource" "build_kubernetes_layer" {
  triggers = {
    build_script = filebase64sha256("${path.module}/lambda/layers/build-kubernetes-layer.sh")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/lambda/layers/build-kubernetes-layer.sh"
  }
}

# Zip the built site-packages. depends_on defers the read to apply time so
# `terraform validate` and `plan` succeed before the layer is built.
data "archive_file" "kubernetes_layer" {
  type        = "zip"
  source_dir  = "${path.module}/.build/kubernetes-layer"
  output_path = "${path.module}/.build/kubernetes-layer.zip"

  depends_on = [null_resource.build_kubernetes_layer]
}

resource "aws_lambda_layer_version" "kubernetes" {
  filename            = data.archive_file.kubernetes_layer.output_path
  layer_name          = "${var.project_name}-kubernetes-py312"
  compatible_runtimes = ["python3.12"]
  source_code_hash    = data.archive_file.kubernetes_layer.output_base64sha256
  description         = "kubernetes Python client for Lambda"
}

# --- IAM Role for Rotation Lambda ---

resource "aws_iam_role" "rotate_api_keys" {
  name = "${var.project_name}-rotate-api-keys"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "rotate_api_keys" {
  name = "rotate-api-keys-policy"
  role = aws_iam_role.rotate_api_keys.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:DescribeSecret",
        ]
        Resource = aws_secretsmanager_secret.hindsight_api_keys.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cognito-idp:ListUsers"]
        Resource = "arn:aws:cognito-idp:${var.aws_region}:${data.aws_caller_identity.current.account_id}:userpool/${local.cognito_user_pool_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        # VPC access for Lambda ENIs. CreateNetworkInterface /
        # DeleteNetworkInterface are scoped to ENI, subnet, and security group
        # resources in this account+region (the ENIs are created dynamically,
        # so a wildcard within these resource types is required).
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*",
        ]
      },
      {
        # DescribeNetworkInterfaces does not support resource-level
        # permissions and must use "*". It is a read-only, non-restrictable
        # action.
        Effect   = "Allow"
        Action   = ["ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      },
    ]
  })
}

# --- Rotation Lambda Function ---

resource "aws_lambda_function" "rotate_api_keys" {
  function_name    = "${var.project_name}-rotate-api-keys"
  role             = aws_iam_role.rotate_api_keys.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.rotate_api_keys.output_path
  source_code_hash = data.archive_file.rotate_api_keys.output_base64sha256

  layers = [aws_lambda_layer_version.kubernetes.arn]

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.rotate_lambda.id]
  }

  environment {
    variables = {
      COGNITO_USER_POOL_ID = local.cognito_user_pool_id
      COGNITO_IDP_PREFIX   = local.cognito_idp_prefix
      SECRET_ID            = aws_secretsmanager_secret.hindsight_api_keys.id
      EKS_CLUSTER_NAME     = module.eks.cluster_name
      K8S_NAMESPACE        = "hindsight"
      K8S_SECRET_NAME      = "hindsight-api-keys"
    }
  }

  tags = local.tags
}

# --- Security Group for Rotation Lambda ---

resource "aws_security_group" "rotate_lambda" {
  name_prefix = "${var.project_name}-rotate-lambda-"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Allow Lambda to reach EKS API server
resource "aws_security_group_rule" "lambda_to_eks" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.rotate_lambda.id
  description              = "Rotation Lambda to EKS API"
}

# --- EKS Access Entry for Lambda ---

resource "aws_eks_access_entry" "rotate_lambda" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.rotate_api_keys.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "rotate_lambda" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.rotate_api_keys.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["hindsight"]
  }
}

# --- Secrets Manager Rotation Schedule ---

resource "aws_lambda_permission" "secretsmanager_rotate" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotate_api_keys.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.hindsight_api_keys.arn
}

resource "aws_secretsmanager_secret_rotation" "hindsight_api_keys" {
  secret_id           = aws_secretsmanager_secret.hindsight_api_keys.id
  rotation_lambda_arn = aws_lambda_function.rotate_api_keys.arn

  rotation_rules {
    schedule_expression = "cron(0 5 * * ? *)"
  }

  depends_on = [aws_lambda_permission.secretsmanager_rotate]
}
