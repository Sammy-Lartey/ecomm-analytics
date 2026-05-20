output "raw_bucket_name" {
  description = "S3 raw landing zone — upload CSVs here"
  value       = aws_s3_bucket.raw.bucket
}

output "redshift_workgroup_endpoint" {
  description = "Redshift Serverless endpoint — paste into dbt profiles.yml"
  value       = aws_redshiftserverless_workgroup.main.endpoint[0].address
}

output "redshift_database" {
  description = "Redshift database name"
  value       = aws_redshiftserverless_namespace.main.db_name
}

output "redshift_iam_role_arn" {
  description = "IAM role ARN — paste into Redshift COPY commands"
  value       = aws_iam_role.redshift.arn
}

output "glue_crawler_name" {
  description = "Glue crawler name — run this after uploading CSVs"
  value       = aws_glue_crawler.raw.name
}
