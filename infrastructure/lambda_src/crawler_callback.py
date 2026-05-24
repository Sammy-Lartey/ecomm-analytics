import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn_client = boto3.client("stepfunctions")


def handler(event, context):
    
    logger.info(f"Received event: {json.dumps(event)}")

    ssm = boto3.client("ssm")
    param_name = "/ecomm-analytics/crawler-task-token"

    # Path 1 — invoked by Step Functions with task token
    if "taskToken" in event:
        task_token = event["taskToken"]
        logger.info("Storing task token in SSM Parameter Store")
        ssm.put_parameter(
            Name      = param_name,
            Value     = task_token,
            Type      = "SecureString",
            Overwrite = True
        )
        logger.info("Task token stored — Step Functions is now paused")
        return {"statusCode": 200, "body": "Token stored"}

    # Path 2 — invoked by EventBridge when crawler finishes
    crawler_state = event.get("detail", {}).get("state", "unknown")
    logger.info(f"EventBridge invocation — crawler state: {crawler_state}")

    if crawler_state != "Succeeded":
        logger.error(f"Crawler did not succeed: {crawler_state}")
        return {"statusCode": 200, "body": f"Crawler state: {crawler_state} — not resuming"}

    # Retrieve stored task token
    try:
        response    = ssm.get_parameter(Name=param_name, WithDecryption=True)
        task_token  = response["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        logger.error("No task token found in SSM — cannot resume Step Functions")
        raise ValueError("Task token not found in SSM Parameter Store")

    logger.info("Sending SendTaskSuccess to Step Functions")
    sfn_client.send_task_success(
        taskToken = task_token,
        output    = json.dumps({"crawlerState": crawler_state})
    )

    # Clean up the token from SSM
    ssm.delete_parameter(Name=param_name)
    logger.info("Task token deleted from SSM — execution resumed")

    return {"statusCode": 200, "body": "SendTaskSuccess sent"}
