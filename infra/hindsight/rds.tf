resource "aws_db_subnet_group" "hindsight" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL from EKS Fargate pods"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_rds_cluster" "hindsight" {
  cluster_identifier = "${var.project_name}-db"
  engine             = "aurora-postgresql"
  engine_version     = "16.4"
  engine_mode        = "provisioned"

  database_name   = "hindsight"
  master_username = "hindsight"
  master_password = var.db_password

  # Encrypt cluster storage at rest with a customer-managed KMS key.
  storage_encrypted = true
  kms_key_id        = aws_kms_key.hindsight.arn

  # Allow IAM database authentication (in addition to password auth).
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.hindsight.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Aurora Serverless v2 scaling (cost-effective for testing)
  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2.0
  }

  skip_final_snapshot = true
  apply_immediately   = true

  tags = local.tags
}

resource "aws_rds_cluster_instance" "hindsight" {
  identifier         = "${var.project_name}-db-1"
  cluster_identifier = aws_rds_cluster.hindsight.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.hindsight.engine
  engine_version     = aws_rds_cluster.hindsight.engine_version

  # Performance Insights with CMK encryption (7-day free retention).
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.hindsight.arn
  performance_insights_retention_period = 7

  tags = local.tags
}
