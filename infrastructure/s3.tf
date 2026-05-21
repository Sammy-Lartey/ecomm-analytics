locals {
  prefix = "${var.project_name}-${var.environment}"
}

# Raw data landing zone 
# CSV files land here untouched — source of truth for the pipeline
# Glue crawler reads from here to register schema in the Data Catalog
# Redshift COPY command reads from here to load the bronze layer
resource "aws_s3_bucket" "raw" {
  bucket        = "${local.prefix}-raw-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Layer       = "raw"
  }
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}
