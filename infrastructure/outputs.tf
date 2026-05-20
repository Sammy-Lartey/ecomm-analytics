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
  description = "Redshift Serverless endpoint"
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
  description = "Name of the Glue crawler"
  value       = aws_glue_crawler.raw.name
}

output "glue_job_name" {
  description = "Name of the Glue ETL job"
  value       = aws_glue_job.transform.name
}

output "step_functions_arn" {
  description = "Step Functions state machine ARN — trigger this to run the full pipeline"
  value       = aws_sfn_state_machine.pipeline.arn
}

output "step_functions_name" {
  description = "Step Functions state machine name"
  value       = aws_sfn_state_machine.pipeline.name
}
