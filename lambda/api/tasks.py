import os
from datetime import datetime, timezone

import boto3

from common import ok

ECS_CLUSTER = os.environ["ECS_CLUSTER"]
CONTAINER_NAME = os.environ["ECS_CONTAINER_NAME"]

ecs = boto3.client("ecs")


def handler(event, context):
    arns = []
    for status in ("RUNNING", "STOPPED"):
        kwargs = dict(cluster=ECS_CLUSTER, desiredStatus=status)
        if status == "STOPPED":
            kwargs["maxResults"] = 20
        page = ecs.list_tasks(**kwargs)
        arns.extend(page.get("taskArns", []))

    if not arns:
        return ok({"tasks": []})

    described = ecs.describe_tasks(cluster=ECS_CLUSTER, tasks=arns)
    tasks = []
    for task in described.get("tasks", []):
        task_id = task["taskArn"].split("/")[-1]

        prompt = None
        for override in task.get("overrides", {}).get("containerOverrides", []):
            if override.get("name") == CONTAINER_NAME:
                for env in override.get("environment", []):
                    if env["name"] == "PROMPT":
                        prompt = env["value"]

        started_at = task.get("startedAt")
        tasks.append({
            "taskId": task_id,
            "status": task.get("lastStatus", "UNKNOWN"),
            "prompt": prompt,
            "startedAt": started_at.astimezone(timezone.utc).isoformat() if started_at else None,
        })

    # Running tasks first, then most recent by startedAt
    tasks.sort(key=lambda t: (
        0 if t["status"] == "RUNNING" else 1,
        -(datetime.fromisoformat(t["startedAt"]).timestamp() if t["startedAt"] else 0),
    ))

    return ok({"tasks": tasks})
