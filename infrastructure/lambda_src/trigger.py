import json
import os
import boto3
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn_client = boto3.client("stepfunctions")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]

# Maps filename pattern → (table_name, primary_key)
TABLE_MAP = {
    "events":    ("events",    "event"),
    "products":  ("products",  "product"),
    "customers": ("customers", "customer"),
}


def resolve_table(key):
    """
    Resolve table name and primary key from filename.
    Supports: events.csv, events_2025_11.csv, sample_events.csv etc.
    """
    filename = key.split("/")[-1].lower().replace(".csv", "")
    for pattern, (table, pk) in TABLE_MAP.items():
        if pattern in filename:
            return table, pk
    return None, None


def handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = record["s3"]["object"]["key"]

        logger.info(f"New file: s3://{bucket}/{key}")

        if not key.endswith(".csv"):
            logger.info(f"Skipping non-CSV: {key}")
            continue

        table, pk = resolve_table(key)
        if not table:
            logger.warning(f"Unrecognised file pattern: {key} — skipping")
            continue

        logger.info(f"Resolved to table={table}, pk={pk}_id")

        timestamp      = datetime.utcnow().strftime("%Y%m%dT%H%M%S")
        filename       = key.replace("/", "_").replace(".", "_")
        execution_name = f"{filename}_{timestamp}"[:80]

        pipeline_input = {
            "bucket": bucket,
            "key":    key,
            "table":  table,
            "pk":     pk
        }

        logger.info(f"Starting execution: {execution_name}")
        logger.info(f"Input: {json.dumps(pipeline_input)}")

        response = sfn_client.start_execution(
            stateMachineArn = STATE_MACHINE_ARN,
            name            = execution_name,
            input           = json.dumps(pipeline_input)
        )

        logger.info(f"Execution ARN: {response['executionArn']}")

    return {"statusCode": 200, "body": "Pipeline triggered"}
