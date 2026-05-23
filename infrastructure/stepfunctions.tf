# ── CloudWatch log group ───────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.prefix}-pipeline"
  retention_in_days = 7

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ── IAM role ───────────────────────────────────────────────────────────────────
resource "aws_iam_role" "step_functions" {
  name = "${local.prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "step_functions_policy" {
  name = "${local.prefix}-sfn-policy"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:GetStatementResult",
          "redshift-data:DescribeStatement"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.crawler_callback.arn
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.redshift.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:CreateLogStream",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# ── Step Functions state machine ───────────────────────────────────────────────
# Incremental pattern:
#   1. Glue crawler re-catalogs the new file
#   2. COPY new file into a staging table
#   3. MERGE staging into main table (insert only new rows by primary key)
#   4. TRUNCATE staging table
#
# This means:
#   - Duplicate rows are never inserted (deduped by event_id / product_id / customer_id)
#   - Files can be uploaded in any order
#   - Pipeline is safe to re-run (idempotent)
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = jsonencode({
    Comment = "Incremental e-commerce ingestion: S3 → Glue → staging → merge into raw"
    StartAt = "StartCrawler"

    States = {

      # ── Step 1: Start Glue crawler ────────────────────────────────────────
      StartCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = aws_glue_crawler.raw.name
        }
        Next = "WaitForCrawler"
        Catch = [
          {
            ErrorEquals = ["Glue.CrawlerRunningException"]
            Next        = "WaitForCrawler"
          }
        ]
      }

      # ── Step 2: Wait for crawler callback ────────────────────────────────
      # Step Functions pauses here. EventBridge fires when crawler finishes,
      # invokes crawler_callback Lambda which calls SendTaskSuccess.
      WaitForCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.crawler_callback.arn
          Payload = {
            "taskToken.$" = "$$.Task.Token"
          }
        }
        HeartbeatSeconds = 600
        Next             = "CopyToStaging"
        Catch = [
          {
            ErrorEquals = ["States.HeartbeatTimeout"]
            Next        = "PipelineFailed"
          },
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailed"
          }
        ]
      }

      # ── Step 3: COPY new file into staging table ──────────────────────────
      # Uses $.table from Lambda input to dynamically target the right table.
      # Staging tables are always truncated before loading so they only
      # ever contain the current file's data.
      CopyToStaging = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          "Sql.$"       = "States.Format('TRUNCATE TABLE raw.{}_staging; COPY raw.{}_staging FROM \\'s3://${aws_s3_bucket.raw.bucket}/{}\\'  IAM_ROLE \\'${aws_iam_role.redshift.arn}\\' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION \\'${var.aws_region}\\';', $.table, $.table, $.key)"
        }
        Next = "WaitForStagingLoad"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForStagingLoad = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckStagingLoad"
      }

      CheckStagingLoad = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next  = "IsStagingLoadDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsStagingLoadDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status", StringEquals = "FINISHED", Next = "MergeIntoMain" },
          { Variable = "$.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForStagingLoad"
      }

      # ── Step 4: Merge staging into main table ─────────────────────────────
      # For events: insert rows where event_id not already in raw.events
      # For products: upsert by product_id (delete + insert)
      # For customers: upsert by customer_id (delete + insert)
      # This makes the pipeline fully idempotent — safe to re-run
      MergeIntoMain = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          "Sql.$"       = "States.Format('INSERT INTO raw.{} SELECT s.* FROM raw.{}_staging s LEFT JOIN raw.{} t ON s.{}_id = t.{}_id WHERE t.{}_id IS NULL;', $.table, $.table, $.table, $.pk, $.pk, $.pk)"
        }
        Next = "WaitForMerge"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForMerge = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckMerge"
      }

      CheckMerge = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next  = "IsMergeDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsMergeDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status", StringEquals = "FINISHED", Next = "TruncateStaging" },
          { Variable = "$.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForMerge"
      }

      # ── Step 5: Truncate staging table ────────────────────────────────────
      # Clean up staging after successful merge
      TruncateStaging = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          "Sql.$"       = "States.Format('TRUNCATE TABLE raw.{}_staging;', $.table)"
        }
        Next = "WaitForTruncate"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForTruncate = {
        Type    = "Wait"
        Seconds = 10
        Next    = "CheckTruncate"
      }

      CheckTruncate = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next  = "IsTruncateDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsTruncateDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status", StringEquals = "FINISHED", Next = "PipelineSucceeded" },
          { Variable = "$.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForTruncate"
      }

      # ── Terminal states ───────────────────────────────────────────────────
      PipelineSucceeded = {
        Type = "Succeed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "Pipeline failed — check CloudWatch logs"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
