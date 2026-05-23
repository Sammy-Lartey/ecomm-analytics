# PIPELINE TRIGGER LAMBDA
# Invoked by S3 when a CSV lands in the raw bucket.
# Starts the Step Functions pipeline execution.

data "archive_file" "trigger" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/trigger.py"
  output_path = "${path.module}/lambda_src/trigger.zip"
}

resource "aws_cloudwatch_log_group" "lambda_trigger" {
  name              = "/aws/lambda/${local.prefix}-pipeline-trigger"
  retention_in_days = 7

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role" "lambda_trigger" {
  name = "${local.prefix}-lambda-trigger-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "lambda_trigger_policy" {
  name = "${local.prefix}-lambda-trigger-policy"
  role = aws_iam_role.lambda_trigger.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda_trigger.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.pipeline.arn
      }
    ]
  })
}

resource "aws_lambda_function" "trigger" {
  function_name    = "${local.prefix}-pipeline-trigger"
  role             = aws_iam_role.lambda_trigger.arn
  runtime          = "python3.12"
  handler          = "trigger.handler"
  filename         = data.archive_file.trigger.output_path
  source_code_hash = data.archive_file.trigger.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.pipeline.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda_trigger]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

resource "aws_s3_bucket_notification" "pipeline_trigger" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}

# CRAWLER CALLBACK LAMBDA
# Invoked by EventBridge when the Glue crawler finishes.
# Sends SendTaskSuccess to Step Functions, resuming the paused execution.

data "archive_file" "crawler_callback" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/crawler_callback.py"
  output_path = "${path.module}/lambda_src/crawler_callback.zip"
}

resource "aws_cloudwatch_log_group" "lambda_crawler_callback" {
  name              = "/aws/lambda/${local.prefix}-crawler-callback"
  retention_in_days = 7

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role" "crawler_callback" {
  name = "${local.prefix}-crawler-callback-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "crawler_callback_policy" {
  name = "${local.prefix}-crawler-callback-policy"
  role = aws_iam_role.crawler_callback.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda_crawler_callback.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "states:SendTaskSuccess"
        Resource = aws_sfn_state_machine.pipeline.arn
      }
    ]
  })
}

resource "aws_lambda_function" "crawler_callback" {
  function_name    = "${local.prefix}-crawler-callback"
  role             = aws_iam_role.crawler_callback.arn
  runtime          = "python3.12"
  handler          = "crawler_callback.handler"
  filename         = data.archive_file.crawler_callback.output_path
  source_code_hash = data.archive_file.crawler_callback.output_base64sha256
  timeout          = 30

  depends_on = [aws_cloudwatch_log_group.lambda_crawler_callback]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_lambda_permission" "eventbridge_invoke_callback" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.crawler_callback.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.crawler_done.arn
}

# EventBridge rule — fires when Glue crawler succeeds, triggering the crawler_callback Lambda
resource "aws_cloudwatch_event_rule" "crawler_done" {
  name        = "${local.prefix}-crawler-done"
  description = "Fires when Glue crawler finishes — triggers callback to Step Functions"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Crawler State Change"]
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

resource "aws_cloudwatch_event_target" "crawler_done_lambda" {
  rule      = aws_cloudwatch_event_rule.crawler_done.name
  target_id = "InvokeCrawlerCallbackLambda"
  arn       = aws_lambda_function.crawler_callback.arn
}
