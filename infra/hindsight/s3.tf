resource "aws_s3_bucket" "hindsight" {
  bucket_prefix = "${var.project_name}-files-"
  force_destroy = true # Allow terraform destroy without manual emptying

  tags = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hindsight" {
  bucket = aws_s3_bucket.hindsight.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "hindsight" {
  bucket = aws_s3_bucket.hindsight.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM policy for Hindsight pods to access S3 (used via IRSA)
resource "aws_iam_policy" "hindsight_s3" {
  name_prefix = "${var.project_name}-s3-"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.hindsight.arn,
          "${aws_s3_bucket.hindsight.arn}/*"
        ]
      }
    ]
  })
}

# IAM policy for Hindsight pods to invoke Bedrock models (used via IRSA)
resource "aws_iam_policy" "hindsight_bedrock" {
  name_prefix = "${var.project_name}-bedrock-"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:Rerank"
        ]
        Resource = "*"
      }
    ]
  })
}
