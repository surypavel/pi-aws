import json
import os

import boto3

from common import err, ok

ECS_CLUSTER = os.environ["ECS_CLUSTER"]
TASK_DEFINITION = os.environ["ECS_TASK_DEFINITION"]
CONTAINER_NAME = os.environ["ECS_CONTAINER_NAME"]
SUBNETS = os.environ["ECS_SUBNETS"].split(",")
SECURITY_GROUP = os.environ["ECS_SECURITY_GROUP"]

ecs = boto3.client("ecs")


def handler(event, context):
    body = json.loads(event.get("body") or "{}") or {}
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        return err(400, "prompt is required")

    response = ecs.run_task(
        cluster=ECS_CLUSTER,
        taskDefinition=TASK_DEFINITION,
        launchType="FARGATE",
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": SUBNETS,
                "securityGroups": [SECURITY_GROUP],
                "assignPublicIp": "ENABLED",
            }
        },
        overrides={
            "containerOverrides": [{
                "name": CONTAINER_NAME,
                "environment": [{"name": "PROMPT", "value": prompt}],
            }]
        },
    )

    if response.get("failures"):
        reason = response["failures"][0].get("reason", "ECS RunTask failed")
        return err(500, reason)

    task_arn = response["tasks"][0]["taskArn"]
    task_id = task_arn.split("/")[-1]
    log_stream = f"pi/pi-agent/{task_id}"

    return ok({"taskId": task_id, "logStream": log_stream})
