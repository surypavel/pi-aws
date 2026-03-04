import os

import boto3
from botocore.exceptions import ClientError

from common import err, ok

ECS_CLUSTER = os.environ["ECS_CLUSTER"]

ecs = boto3.client("ecs")


def handler(event, context):
    task_id = event["pathParameters"]["taskId"]
    try:
        ecs.stop_task(cluster=ECS_CLUSTER, task=task_id, reason="Stopped by user via pi-aws UI")
    except ClientError as e:
        if e.response["Error"]["Code"] in ("InvalidParameterException", "ClusterNotFoundException"):
            return err(404, "Task not found")
        raise
    return ok({"stopped": task_id})
