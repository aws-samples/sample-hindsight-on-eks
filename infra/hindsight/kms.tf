# Customer-managed KMS key for encrypting data at rest across the deployment:
# Aurora storage + Performance Insights, Secrets Manager secrets, and
# API Gateway access logs. Using a single CMK keeps key management simple for
# this sample while satisfying CMK-encryption controls.

resource "aws_kms_key" "hindsight" {
  description             = "${var.project_name} CMK for RDS, Secrets Manager, and CloudWatch Logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.tags
}

resource "aws_kms_alias" "hindsight" {
  name          = "alias/${var.project_name}"
  target_key_id = aws_kms_key.hindsight.key_id
}

# Allow CloudWatch Logs (API Gateway access logs) to use the CMK.
data "aws_iam_policy_document" "kms" {
  # The root-account statement below is the AWS-recommended default key policy.
  # In a KMS *key policy*, Resource="*" scopes to this key only (not all account
  # resources), and removing root admin access can make the key permanently
  # unmanageable. These are well-known false positives for KMS key policies.
  #checkov:skip=CKV_AWS_109:Root admin on the key it's attached to is the AWS-recommended default key policy
  #checkov:skip=CKV_AWS_111:Root admin on the key it's attached to is the AWS-recommended default key policy
  #checkov:skip=CKV_AWS_356:Resource="*" in a KMS key policy scopes to this key only, not account-wide
  # Default: account root retains full administrative control of the key.
  statement {
    sid       = "EnableRootAccountPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # Allow the CloudWatch Logs service in this region to encrypt/decrypt log data.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_kms_key_policy" "hindsight" {
  key_id = aws_kms_key.hindsight.id
  policy = data.aws_iam_policy_document.kms.json
}
