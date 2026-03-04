import os

import boto3
from botocore.exceptions import ClientError

from common import ok

ECS_CLUSTER = os.environ["ECS_CLUSTER"]
LOG_GROUP = os.environ["LOG_GROUP"]

ecs = boto3.client("ecs")
logs = boto3.client("logs")


def handler(event, context):
    task_id = event["pathParameters"]["taskId"]
    qs = event.get("queryStringParameters") or {}
    next_token = qs.get("nextToken")

    # Resolve current task status (default STOPPED if task is gone / expired)
    status = "STOPPED"
    try:
        resp = ecs.describe_tasks(cluster=ECS_CLUSTER, tasks=[task_id])
        tasks = resp.get("tasks", [])
        if tasks:
            status = tasks[0].get("lastStatus", "STOPPED")
    except ClientError:
        pass

    # Fetch log events (incremental via nextToken)
    log_stream = f"pi/pi-agent/{task_id}"
    kwargs = dict(logGroupName=LOG_GROUP, logStreamName=log_stream, startFromHead=True)
    if next_token:
        kwargs["nextToken"] = next_token

    try:
        resp = logs.get_log_events(**kwargs)
        lines = [e["message"] for e in resp.get("events", [])]
        new_token = resp.get("nextForwardToken")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ResourceNotFoundException":
            lines = []
            new_token = None
        else:
            raise

    return ok({"lines": lines, "nextToken": new_token, "status": status})
