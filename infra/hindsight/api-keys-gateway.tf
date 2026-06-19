# API Gateway + Lambda for key retrieval (auth.hindsight.example.com)

# --- Lambda Packaging ---

data "archive_file" "get_api_key" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/get-api-key"
  output_path = "${path.module}/.build/get-api-key.zip"
}

# --- IAM Role ---

resource "aws_iam_role" "get_api_key" {
  name = "${var.project_name}-get-api-key"

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

resource "aws_iam_role_policy" "get_api_key" {
  name = "get-api-key-policy"
  role = aws_iam_role.get_api_key.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.hindsight_api_keys.arn
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
    ]
  })
}

# --- Lambda Function ---

resource "aws_lambda_function" "get_api_key" {
  function_name    = "${var.project_name}-get-api-key"
  role             = aws_iam_role.get_api_key.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.get_api_key.output_path
  source_code_hash = data.archive_file.get_api_key.output_base64sha256

  environment {
    variables = {
      SECRET_ID          = aws_secretsmanager_secret.hindsight_api_keys.id
      COGNITO_IDP_PREFIX = local.cognito_idp_prefix
    }
  }

  tags = local.tags
}

# --- API Gateway HTTP API ---

resource "aws_apigatewayv2_api" "auth" {
  name          = "${var.project_name}-auth"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET"]
    allow_headers = ["Authorization"]
  }

  tags = local.tags
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.auth.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.hindsight_mcp.id]
    issuer   = local.cognito_issuer
  }
}

resource "aws_apigatewayv2_integration" "get_api_key" {
  api_id                 = aws_apigatewayv2_api.auth.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_api_key.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_my_key" {
  api_id             = aws_apigatewayv2_api.auth.id
  route_key          = "GET /my-key"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  target             = "integrations/${aws_apigatewayv2_integration.get_api_key.id}"
}

# --- Access Logging ---

resource "aws_cloudwatch_log_group" "auth_api" {
  name              = "/aws/apigateway/${var.project_name}-auth"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.hindsight.arn

  tags = local.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.auth.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.auth_api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = local.tags
}

resource "aws_lambda_permission" "apigw_get_key" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_api_key.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.auth.execution_arn}/*/*"
}

# --- Custom Domain (auth.hindsight.example.com) ---

resource "aws_acm_certificate" "auth" {
  count             = var.public_endpoint ? 1 : 0
  domain_name       = "auth.${var.hindsight_domain}"
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "auth_cert_validation" {
  for_each = var.public_endpoint ? {
    for dvo in aws_acm_certificate.auth[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "auth" {
  count                   = var.public_endpoint ? 1 : 0
  certificate_arn         = aws_acm_certificate.auth[0].arn
  validation_record_fqdns = [for record in aws_route53_record.auth_cert_validation : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "auth" {
  count       = var.public_endpoint ? 1 : 0
  domain_name = "auth.${var.hindsight_domain}"

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.auth[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.tags
}

resource "aws_apigatewayv2_api_mapping" "auth" {
  count       = var.public_endpoint ? 1 : 0
  api_id      = aws_apigatewayv2_api.auth.id
  domain_name = aws_apigatewayv2_domain_name.auth[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "auth" {
  count   = var.public_endpoint ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = "auth.${var.hindsight_domain}"
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.auth[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.auth[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
