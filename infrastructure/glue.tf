# Glue data catalog database
resource "aws_glue_catalog_database" "raw" {
  name        = "${replace(local.prefix, "-", "_")}_raw"
  description = "Glue catalog for raw e-commerce CSV data"
}

# Glue crawler — discovers schema from S3 raw zone
resource "aws_glue_crawler" "raw" {
  name          = "${local.prefix}-raw-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.raw.name
  description   = "Crawls raw CSV files and registers schema in Glue catalog"

  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
