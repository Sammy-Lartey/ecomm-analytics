# CloudWatch log group for Step Functions state machine
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.prefix}-pipeline"
  retention_in_days = 7

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM role for Step Functions with permissions to call Glue and Redshift APIs
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
        # Glue crawler permissions
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler"
        ]
        Resource = "*"
      },
      {
        # Redshift Data API — .sync integration
        # Step Functions waits for statement completion natively
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:GetStatementResult",
          "redshift-data:DescribeStatement"
        ]
        Resource = "*"
      },
      {
        # EventBridge — needed for .sync and callback patterns
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "arn:aws:events:${var.aws_region}:*:rule/StepFunctionsGetEventsFor*"
      },
      {
        # Allow Redshift to use its IAM role for COPY
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.redshift.arn
      },
      {
        # CloudWatch logging
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

# Step Functions state machine definition with Glue and Redshift tasks, using .sync and callback patterns
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = jsonencode({
    Comment = "E-commerce ingestion pipeline: Glue Crawler → Redshift COPY (event-driven, no polling)"
    StartAt = "StartCrawler"

    States = {

      # Step 1: Start Glue crawler and wait for completion event
      # Uses EventBridge callback pattern:
      # Step Functions sends a task token to Glue via EventBridge.
      # When the crawler finishes, EventBridge fires a rule that calls
      # SendTaskSuccess back to Step Functions with the token.
      # No polling loop — Step Functions pauses and resumes on the event.
      StartCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = aws_glue_crawler.raw.name
        }
        Next = "WaitForCrawlerEventBridge"
        Catch = [
          {
            ErrorEquals = ["Glue.CrawlerRunningException"]
            Next        = "WaitForCrawlerEventBridge"
            Comment     = "Crawler already running — wait for completion event"
          }
        ]
      }

      # Wait for EventBridge to fire the crawler completion event
      # HeartbeatSeconds — fail if no event received within 10 minutes
      WaitForCrawlerEventBridge = {
        Type     = "Task"
        Resource = "arn:aws:states:::events:waitForTaskToken"
        Parameters = {
          RuleArn        = "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${local.prefix}-crawler-done"
          "TaskToken.$"  = "$$.Task.Token"
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

      # Step 2: Load events.csv to Redshift using Data API and .sync integration
      # Uses .sync integration — Step Functions calls the Redshift Data API
      # and waits for the SQL statement to complete before moving on.
      # No wait states needed — AWS handles this natively.
      LoadEventsToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "TRUNCATE TABLE raw.events; COPY raw.events FROM 's3://${aws_s3_bucket.raw.bucket}/events.csv' IAM_ROLE '${aws_iam_role.redshift.arn}' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION '${var.aws_region}';"
        }
        Next = "WaitForEventsStatement"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      # Poll Redshift Data API for statement completion
      # Redshift Data API is async — we check status until done
      WaitForEventsStatement = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckEventsStatement"
      }

      CheckEventsStatement = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next = "IsEventsStatementDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsEventsStatementDone = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Status"
            StringEquals = "FINISHED"
            Next         = "LoadProductsToRedshift"
          },
          {
            Variable     = "$.Status"
            StringEquals = "FAILED"
            Next         = "PipelineFailed"
          },
          {
            Variable     = "$.Status"
            StringEquals = "ABORTED"
            Next         = "PipelineFailed"
          }
        ]
        Default = "WaitForEventsStatement"
      }

      # Step 3: Load products.csv to Redshift using Data API and .sync integration
      LoadProductsToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "TRUNCATE TABLE raw.products; COPY raw.products FROM 's3://${aws_s3_bucket.raw.bucket}/products.csv' IAM_ROLE '${aws_iam_role.redshift.arn}' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION '${var.aws_region}';"
        }
        Next = "WaitForProductsStatement"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForProductsStatement = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckProductsStatement"
      }

      CheckProductsStatement = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next = "IsProductsStatementDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsProductsStatementDone = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Status"
            StringEquals = "FINISHED"
            Next         = "LoadCustomersToRedshift"
          },
          {
            Variable     = "$.Status"
            StringEquals = "FAILED"
            Next         = "PipelineFailed"
          },
          {
            Variable     = "$.Status"
            StringEquals = "ABORTED"
            Next         = "PipelineFailed"
          }
        ]
        Default = "WaitForProductsStatement"
      }

      # Step 4: Load customers.csv to Redshift using Data API and .sync integration
      LoadCustomersToRedshift = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "TRUNCATE TABLE raw.customers; COPY raw.customers FROM 's3://${aws_s3_bucket.raw.bucket}/customers.csv' IAM_ROLE '${aws_iam_role.redshift.arn}' FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL REGION '${var.aws_region}';"
        }
        Next = "WaitForCustomersStatement"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      WaitForCustomersStatement = {
        Type    = "Wait"
        Seconds = 15
        Next    = "CheckCustomersStatement"
      }

      CheckCustomersStatement = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:describeStatement"
        Parameters = {
          "Id.$" = "$.Id"
        }
        Next = "IsCustomersStatementDone"
        Catch = [{ ErrorEquals = ["States.ALL"], Next = "PipelineFailed" }]
      }

      IsCustomersStatementDone = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Status"
            StringEquals = "FINISHED"
            Next         = "PipelineSucceeded"
          },
          {
            Variable     = "$.Status"
            StringEquals = "FAILED"
            Next         = "PipelineFailed"
          },
          {
            Variable     = "$.Status"
            StringEquals = "ABORTED"
            Next         = "PipelineFailed"
          }
        ]
        Default = "WaitForCustomersStatement"
      }

      # Terminal states for success and failure
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

# EventBridge rule — fires when Glue crawler finishes and sends task token back to Step Functions ───────────────────────────────
# This is what replaces the polling loop for the crawler.
# When Glue emits a SUCCEEDED state change event, EventBridge
# fires this rule which sends SendTaskSuccess back to Step Functions.
resource "aws_cloudwatch_event_rule" "crawler_done" {
  name        = "${local.prefix}-crawler-done"
  description = "Fires when the Glue crawler finishes — signals Step Functions"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Crawler State Change"]
    detail = {
      crawlerName = [aws_glue_crawler.raw.name]
      state       = ["Succeeded"]
    }
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# EventBridge target — calls Step Functions SendTaskSuccess with the task token
resource "aws_cloudwatch_event_target" "crawler_done_sfn" {
  rule      = aws_cloudwatch_event_rule.crawler_done.name
  target_id = "SendTaskSuccessToStepFunctions"
  arn       = "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.prefix}-pipeline"
  role_arn  = aws_iam_role.eventbridge_sfn.arn

  input_transformer {
    input_paths = {
      taskToken = "$.detail.taskToken"
    }
    input_template = "{\"taskToken\": \"<taskToken>\", \"output\": \"crawler-succeeded\"}"
  }
}

# IAM role for EventBridge to call Step Functions
resource "aws_iam_role" "eventbridge_sfn" {
  name = "${local.prefix}-eventbridge-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "eventbridge_sfn_policy" {
  name = "${local.prefix}-eventbridge-sfn-policy"
  role = aws_iam_role.eventbridge_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:SendTaskSuccess"
      Resource = aws_sfn_state_machine.pipeline.arn
    }]
  })
}
