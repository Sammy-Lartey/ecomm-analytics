# ── Glue data catalog database ────────────────────────────────────────────────
resource "aws_glue_catalog_database" "raw" {
  name        = "${replace(local.prefix, "-", "_")}_raw"
  description = "Glue catalog for raw e-commerce CSV data"
}

# ── Glue crawler — discovers schema from S3 raw zone ─────────────────────────
resource "aws_glue_crawler" "raw" {
  name          = "${local.prefix}-raw-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.raw.name
  description   = "Crawls raw CSV files and registers schema in Glue catalog"

  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/ecommerce/"
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

# ── Glue ETL job — transforms raw CSVs to Parquet in processed bucket ─────────
resource "aws_glue_job" "transform" {
  name         = "${local.prefix}-transform-job"
  role_arn     = aws_iam_role.glue.arn
  description  = "Cleans and transforms raw e-commerce CSVs into Parquet"
  glue_version = "4.0"
  worker_type  = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/transform.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.glue_scripts.bucket}/spark-logs/"
    "--RAW_BUCKET"                       = aws_s3_bucket.raw.bucket
    "--PROCESSED_BUCKET"                 = aws_s3_bucket.processed.bucket
    "--REDSHIFT_URL"                     = "jdbc:redshift://${aws_redshiftserverless_workgroup.main.endpoint[0].address}:5439/ecomm_db"
    "--REDSHIFT_ROLE"                    = aws_iam_role.redshift.arn
    "--REDSHIFT_TMP_DIR"                 = "s3://${aws_s3_bucket.glue_scripts.bucket}/redshift-tmp/"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
