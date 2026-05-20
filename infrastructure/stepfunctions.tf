# ── CloudWatch log group for Step Functions ───────────────────────────────────
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.prefix}-pipeline"
  retention_in_days = 7

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ── Step Functions state machine ──────────────────────────────────────────────
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.prefix}-pipeline"
  role_arn = aws_iam_role.step_functions.arn

  definition = jsonencode({
    Comment = "E-commerce analytics pipeline: Crawl → Transform → Load"
    StartAt = "StartCrawler"

    States = {

      # ── Step 1: Start the Glue crawler ──────────────────────────────────────
      StartCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = aws_glue_crawler.raw.name
        }
        Next  = "WaitForCrawler"
        Catch = [{
          ErrorEquals = ["Glue.CrawlerRunningException"]
          Next        = "WaitForCrawler"
        }]
      }

      # ── Step 2: Poll crawler until READY ────────────────────────────────────
      WaitForCrawler = {
        Type    = "Wait"
        Seconds = 30
        Next    = "CheckCrawlerStatus"
      }

      CheckCrawlerStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = {
          Name = aws_glue_crawler.raw.name
        }
        Next = "IsCrawlerReady"
      }

      IsCrawlerReady = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.Crawler.State"
            StringEquals  = "READY"
            Next          = "StartGlueJob"
          }
        ]
        Default = "WaitForCrawler"
      }

      # ── Step 3: Run the Glue ETL job ────────────────────────────────────────
      StartGlueJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = aws_glue_job.transform.name
        }
        Next = "CreateRedshiftSchema"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "PipelineFailed"
        }]
      }

      # ── Step 4: Create Redshift schema and tables ────────────────────────────
      CreateRedshiftSchema = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:redshiftdata:executeStatement"
        Parameters = {
          WorkgroupName = aws_redshiftserverless_workgroup.main.workgroup_name
          Database      = "ecomm_db"
          Sql           = "CREATE SCHEMA IF NOT EXISTS staging;"
        }
        Next = "WaitForSchema"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "PipelineFailed"
        }]
      }

      WaitForSchema = {
        Type    = "Wait"
        Seconds = 5
        Next    = "PipelineSucceeded"
      }

      # ── Terminal states ──────────────────────────────────────────────────────
      PipelineSucceeded = {
        Type = "Succeed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "One or more pipeline steps failed. Check CloudWatch logs."
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
