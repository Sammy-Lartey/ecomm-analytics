import json
import os
import boto3
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn_client = boto3.client("stepfunctions")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def handler(event, context):
    """
    Triggered by S3 ObjectCreated events.
    Starts the Step Functions pipeline state machine when a CSV lands
    in the raw S3 bucket.
    """
    logger.info(f"Received event: {json.dumps(event)}")

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = record["s3"]["object"]["key"]

        logger.info(f"New file detected: s3://{bucket}/{key}")

        # only process CSV files
        if not key.endswith(".csv"):
            logger.info(f"Skipping non-CSV file: {key}")
            continue

        # unique execution name from filename + timestamp
        filename       = key.replace("/", "_").replace(".", "_")
        timestamp      = datetime.utcnow().strftime("%Y%m%dT%H%M%S")
        execution_name = f"{filename}_{timestamp}"[:80]

        pipeline_input = {
            "bucket": bucket,
            "key":    key,
            "file":   key.split("/")[-1].replace(".csv", "")
        }

        logger.info(f"Starting Step Functions: {execution_name}")

        response = sfn_client.start_execution(
            stateMachineArn = STATE_MACHINE_ARN,
            name            = execution_name,
            input           = json.dumps(pipeline_input)
        )

        logger.info(f"Execution started: {response['executionArn']}")

    return {"statusCode": 200, "body": "Pipeline triggered"}
