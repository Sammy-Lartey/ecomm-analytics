# ── CloudWatch log group ───────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.prefix}-pipeline"
  retention_in_days = 7
  tags = { Project = var.project_name, Environment = var.environment }
}

# ── IAM role ───────────────────────────────────────────────────────────────────
resource "aws_iam_role" "step_functions" {
  name = "${local.prefix}-sfn-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = { Project = var.project_name, Environment = var.environment }
}

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "${local.prefix}-sfn-policy"
  role = aws_iam_role.step_functions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["glue:StartCrawler", "glue:GetCrawler"], Resource = "*" },
      { Effect = "Allow", Action = ["redshift-data:ExecuteStatement", "redshift-data:GetStatementResult", "redshift-data:DescribeStatement"], Resource = "*" },
      { Effect = "Allow", Action = "redshift-serverless:GetCredentials", Resource = "*" },
      { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.crawler_callback.arn },
      { Effect = "Allow", Action = "iam:PassRole", Resource = aws_iam_role.redshift.arn },
      { Effect = "Allow", Action = ["logs:CreateLogDelivery", "logs:CreateLogStream", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutLogEvents", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"], Resource = "*" }
    ]
  })
}

locals {
  workgroup_name = aws_redshiftserverless_workgroup.main.workgroup_name
}

# ── Step Functions state machine ───────────────────────────────────────────────
# SQL strings are built in Lambda (trigger.py) and passed as pipeline input:
#   $.copySql  — COPY statement with real bucket, role ARN, region
#   $.mergeSql — INSERT statement to merge staging into main table
# This avoids all Terraform string escaping issues entirely.
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = jsonencode({
    Comment = "Incremental e-commerce ingestion: S3 -> Glue -> staging -> merge"
    StartAt = "StartCrawler"
    States = {

      StartCrawler = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = { Name = aws_glue_crawler.raw.name }
        ResultPath = "$.crawlerStarted"
        Next       = "WaitForCrawler"
        Catch      = [{ ErrorEquals = ["Glue.CrawlerRunningException"], Next = "WaitForCrawler" }]
      }

      WaitForCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.crawler_callback.arn
          Payload = {
            "taskToken.$"     = "$$.Task.Token"
            "table.$"         = "$.table"
            "key.$"           = "$.key"
            "pk.$"            = "$.pk"
            "workgroupName.$" = "$.workgroupName"
            "copySql.$"       = "$.copySql"
            "mergeSql.$"      = "$.mergeSql"
          }
        }
        HeartbeatSeconds = 600
        ResultPath       = "$.crawlerResult"
        Next             = "CopyToStaging"
        Catch = [
          { ErrorEquals = ["States.HeartbeatTimeout"], Next = "PipelineFailed" },
          { ErrorEquals = ["States.ALL"],              Next = "PipelineFailed" }
        ]
      }

      CopyToStaging = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          "WorkgroupName.$" = "$.workgroupName"
          Database          = "ecomm_db"
          "Sql.$"           = "$.copySql"
        }
        ResultPath = "$.stagingResult"
        Next       = "WaitForStaging"
        Catch      = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForStaging = {
        Type    = "Wait"
        Seconds = 20
        Next    = "CheckStaging"
      }

      CheckStaging = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = { "Id.$" = "$.stagingResult.Id" }
        ResultPath = "$.stagingStatus"
        Next       = "IsStagingDone"
        Catch      = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsStagingDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.stagingStatus.Status", StringEquals = "FINISHED", Next = "MergeIntoMain" },
          { Variable = "$.stagingStatus.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.stagingStatus.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForStaging"
      }

      MergeIntoMain = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          "WorkgroupName.$" = "$.workgroupName"
          Database          = "ecomm_db"
          "Sql.$"           = "$.mergeSql"
        }
        ResultPath = "$.mergeResult"
        Next       = "WaitForMerge"
        Catch      = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForMerge = {
        Type    = "Wait"
        Seconds = 20
        Next    = "CheckMerge"
      }

      CheckMerge = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = { "Id.$" = "$.mergeResult.Id" }
        ResultPath = "$.mergeStatus"
        Next       = "IsMergeDone"
        Catch      = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsMergeDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.mergeStatus.Status", StringEquals = "FINISHED", Next = "PipelineSucceeded" },
          { Variable = "$.mergeStatus.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.mergeStatus.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForMerge"
      }

      PipelineSucceeded = { Type = "Succeed" }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "Pipeline failed - check CloudWatch logs"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = { Project = var.project_name, Environment = var.environment }
}
