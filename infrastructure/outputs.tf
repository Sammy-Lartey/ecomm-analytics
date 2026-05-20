output "raw_bucket_name" {
  description = "S3 raw landing zone bucket name"
  value       = aws_s3_bucket.raw.bucket
}

output "processed_bucket_name" {
  description = "S3 processed zone bucket name"
  value       = aws_s3_bucket.processed.bucket
}

output "glue_scripts_bucket_name" {
  description = "S3 bucket for Glue scripts"
  value       = aws_s3_bucket.glue_scripts.bucket
}

output "redshift_workgroup_endpoint" {
  description = "Redshift Serverless endpoint — use this in dbt profiles.yml"
  value       = aws_redshiftserverless_workgroup.main.endpoint[0].address
}

output "redshift_database" {
  description = "Redshift database name"
  value       = aws_redshiftserverless_namespace.main.db_name
}

output "redshift_iam_role_arn" {
  description = "IAM role ARN for Redshift COPY commands"
  value       = aws_iam_role.redshift.arn
}

output "glue_role_arn" {
  description = "IAM role ARN for Glue jobs and crawlers"
  value       = aws_iam_role.glue.arn
}

output "glue_crawler_name" {
  description = "Name of the Glue crawler to run after uploading CSV"
  value       = aws_glue_crawler.raw.name
}
