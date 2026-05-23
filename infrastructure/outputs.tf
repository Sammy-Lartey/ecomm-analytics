output "raw_bucket_name" {
  description = "S3 raw landing zone — CSVs are uploaded here"
  value       = aws_s3_bucket.raw.bucket
}

output "redshift_workgroup_endpoint" {
  description = "Redshift Serverless endpoint — goes into dbt profiles.yml"
  value       = aws_redshiftserverless_workgroup.main.endpoint[0].address
}

output "redshift_database" {
  description = "Redshift database name"
  value       = aws_redshiftserverless_namespace.main.db_name
}

output "redshift_iam_role_arn" {
  description = "IAM role ARN — goes into Redshift COPY commands"
  value       = aws_iam_role.redshift.arn
}

output "glue_crawler_name" {
  description = "Glue crawler name — run after uploading CSVs"
  value       = aws_glue_crawler.raw.name
}

output "lambda_function_name" {
  description = "Lambda trigger function name"
  value       = aws_lambda_function.trigger.function_name
}

output "step_functions_arn" {
  description = "Step Functions state machine ARN"
  value       = aws_sfn_state_machine.pipeline.arn
}

output "step_functions_name" {
  description = "Step Functions state machine name — drop a CSV in S3 to trigger"
  value       = aws_sfn_state_machine.pipeline.name
}