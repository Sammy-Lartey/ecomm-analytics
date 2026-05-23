# CloudWatch log group for Step Functions
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.prefix}-pipeline"
  retention_in_days = 7

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM role for Step Functions
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
        # Invoke the crawler callback Lambda with task token — allowing Step Functions to pause and wait for the crawler to finish
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

# Step Functions state machine definition:
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = jsonencode({
    Comment = "E-commerce ingestion pipeline: Glue Crawler → Redshift COPY"
    StartAt = "StartCrawler"

    States = {

      # Step 1: Start Glue crawler — if it's already running, catch the error and proceed to wait for the callback
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
            Comment     = "Crawler already running — wait for callback"
          }
        ]
      }

      # Step 2: Pause and wait for EventBridge callback — invoked when Glue crawler finishes
      # Invokes the crawler_callback Lambda with a task token.
      # Step Functions pauses here. When the Glue crawler finishes,
      # EventBridge fires, invoking crawler_callback Lambda which calls
      # SendTaskSuccess with the token — resuming the execution.
      WaitForCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName   = aws_lambda_function.crawler_callback.arn
          "Payload" = {
            "taskToken.$" = "$$.Task.Token"
          }
        }
        HeartbeatSeconds = 600
        Next             = "LoadEventsToRedshift"
        Catch = [
          {
            ErrorEquals = ["States.HeartbeatTimeout"]
            Next        = "PipelineFailed"
            Comment     = "Crawler did not complete within 10 minutes"
          },
          {
            ErrorEquals = ["States.ALL"]
            Next        = "PipelineFailed"
          }
        ]
      }

      # ── Step 3: Load events.csv ───────────────────────────────────────────
      LoadEventsToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "TRUNCATE TABLE raw.events; COPY raw.events FROM 's3://${aws_s3_bucket.raw.bucket}/events.csv' IAM_ROLE '${aws_iam_role.redshift.arn}' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION '${var.aws_region}';"
        }
        Next = "WaitForEventsLoad"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForEventsLoad = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckEventsLoad"
      }

      CheckEventsLoad = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next  = "IsEventsLoadDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsEventsLoadDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status", StringEquals = "FINISHED", Next = "LoadProductsToRedshift" },
          { Variable = "$.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForEventsLoad"
      }

      # Step 4: Load products.csv ─ similar pattern to events.csv, with polling to check when the load is finished
      LoadProductsToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "TRUNCATE TABLE raw.products; COPY raw.products FROM 's3://${aws_s3_bucket.raw.bucket}/products.csv' IAM_ROLE '${aws_iam_role.redshift.arn}' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION '${var.aws_region}';"
        }
        Next = "WaitForProductsLoad"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForProductsLoad = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckProductsLoad"
      }

      CheckProductsLoad = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next  = "IsProductsLoadDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsProductsLoadDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status", StringEquals = "FINISHED", Next = "LoadCustomersToRedshift" },
          { Variable = "$.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForProductsLoad"
      }

      # Step 5: Load customers.csv 
      LoadCustomersToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "TRUNCATE TABLE raw.customers; COPY raw.customers FROM 's3://${aws_s3_bucket.raw.bucket}/customers.csv' IAM_ROLE '${aws_iam_role.redshift.arn}' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION '${var.aws_region}';"
        }
        Next = "WaitForCustomersLoad"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForCustomersLoad = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckCustomersLoad"
      }

      CheckCustomersLoad = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next  = "IsCustomersLoadDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsCustomersLoadDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status", StringEquals = "FINISHED", Next = "PipelineSucceeded" },
          { Variable = "$.Status", StringEquals = "FAILED",   Next = "PipelineFailed" },
          { Variable = "$.Status", StringEquals = "ABORTED",  Next = "PipelineFailed" }
        ]
        Default = "WaitForCustomersLoad"
      }

      # Terminal states
      PipelineSucceeded = {
        Type = "Succeed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "Pipeline failed — check CloudWatch logs for details"
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
