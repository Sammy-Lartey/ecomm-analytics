import json
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn_client = boto3.client("stepfunctions")

CONTEXT_FIELDS = ["table", "key", "pk", "workgroupName", "copySql", "mergeSql"]


def handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")

    ssm         = boto3.client("ssm")
    token_key   = "/ecomm-analytics/crawler-task-token"
    context_key = "/ecomm-analytics/crawler-pipeline-context"

    # Path 1 — Step Functions invokes with task token
    if "taskToken" in event:
        ssm.put_parameter(
            Name=token_key, Value=event["taskToken"],
            Type="SecureString", Overwrite=True
        )
        pipeline_context = {k: event.get(k) for k in CONTEXT_FIELDS}
        ssm.put_parameter(
            Name=context_key, Value=json.dumps(pipeline_context),
            Type="String", Overwrite=True
        )
        logger.info(f"Stored token and context: {list(pipeline_context.keys())}")
        return {"statusCode": 200}

    # Path 2 — EventBridge invokes when crawler finishes
    crawler_state = event.get("detail", {}).get("state", "unknown")
    logger.info(f"Crawler state: {crawler_state}")

    if crawler_state != "Succeeded":
        logger.error(f"Crawler did not succeed: {crawler_state}")
        return {"statusCode": 200}

    token_resp      = ssm.get_parameter(Name=token_key, WithDecryption=True)
    task_token      = token_resp["Parameter"]["Value"]
    ctx_resp        = ssm.get_parameter(Name=context_key)
    pipeline_context = json.loads(ctx_resp["Parameter"]["Value"])

    output = {"crawlerState": crawler_state}
    output.update(pipeline_context)

    logger.info(f"Sending SendTaskSuccess. Output keys: {list(output.keys())}")
    logger.info(f"copySql preview: {output.get('copySql', '')[:100]}")

    sfn_client.send_task_success(
        taskToken=task_token,
        output=json.dumps(output)
    )

    ssm.delete_parameter(Name=token_key)
    ssm.delete_parameter(Name=context_key)
    logger.info("SSM cleaned — execution resumed")

    return {"statusCode": 200}