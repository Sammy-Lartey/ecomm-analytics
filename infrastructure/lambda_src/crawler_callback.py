import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn_client = boto3.client("stepfunctions")


def handler(event, context):
    """
    Invoked by EventBridge when the Glue crawler finishes.
    Sends SendTaskSuccess back to Step Functions using the task token
    stored in the event detail, resuming the paused execution.
    """
    logger.info(f"Received event: {json.dumps(event)}")

    task_token = event.get("detail", {}).get("taskToken")

    if not task_token:
        logger.error("No task token found in event — cannot resume Step Functions")
        raise ValueError("Missing taskToken in event detail")

    crawler_state = event.get("detail", {}).get("state", "unknown")
    logger.info(f"Crawler finished with state: {crawler_state}")

    sfn_client.send_task_success(
        taskToken = task_token,
        output    = json.dumps({"crawlerState": crawler_state})
    )

    logger.info("SendTaskSuccess sent — Step Functions execution resumed")
    return {"statusCode": 200}
