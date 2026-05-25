import json
import os
import boto3
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn_client        = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
REDSHIFT_ROLE_ARN = os.environ["REDSHIFT_ROLE_ARN"]
RAW_BUCKET        = os.environ["RAW_BUCKET"]
AWS_REGION_NAME   = os.environ["AWS_REGION_NAME"]
WORKGROUP_NAME    = os.environ["WORKGROUP_NAME"]

TABLE_MAP = {
    "events":    ("events",    "event"),
    "products":  ("products",  "product"),
    "customers": ("customers", "customer"),
}


def resolve_table(key):
    filename = key.split("/")[-1].lower().replace(".csv", "")
    for pattern, (table, pk) in TABLE_MAP.items():
        if pattern in filename:
            return table, pk
    return None, None


def build_copy_sql(table, key):
    """Build the COPY SQL string in Python — no escaping issues."""
    return (
        f"set search_path to raw; "
        f"COPY {table}_staging "
        f"FROM 's3://{RAW_BUCKET}/{key}' "
        f"IAM_ROLE '{REDSHIFT_ROLE_ARN}' "
        f"FORMAT AS CSV IGNOREHEADER 1 EMPTYASNULL BLANKSASNULL "
        f"REGION '{AWS_REGION_NAME}'"
    )


def build_merge_sql(table, pk):
    """Build the INSERT/merge SQL string in Python."""
    return (
        f"set search_path to raw; "
        f"INSERT INTO {table} "
        f"SELECT s.* FROM {table}_staging s "
        f"LEFT JOIN {table} t ON s.{pk}_id = t.{pk}_id "
        f"WHERE t.{pk}_id IS NULL"
    )


def handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = record["s3"]["object"]["key"]

        if not key.endswith(".csv"):
            continue

        table, pk = resolve_table(key)
        if not table:
            logger.warning(f"Unrecognised file: {key}")
            continue

        copy_sql  = build_copy_sql(table, key)
        merge_sql = build_merge_sql(table, pk)

        logger.info(f"COPY SQL: {copy_sql}")
        logger.info(f"MERGE SQL: {merge_sql}")

        timestamp      = datetime.utcnow().strftime("%Y%m%dT%H%M%S")
        filename       = key.replace("/", "_").replace(".", "_")
        execution_name = f"{filename}_{timestamp}"[:80]

        pipeline_input = {
            "bucket":        bucket,
            "key":           key,
            "table":         table,
            "pk":            pk,
            "workgroupName": WORKGROUP_NAME,
            "copySql":       copy_sql,
            "mergeSql":      merge_sql
        }

        logger.info(f"Starting execution: {execution_name}")

        response = sfn_client.start_execution(
            stateMachineArn = STATE_MACHINE_ARN,
            name            = execution_name,
            input           = json.dumps(pipeline_input)
        )

        logger.info(f"Execution ARN: {response['executionArn']}")

    return {"statusCode": 200, "body": "Pipeline triggered"}