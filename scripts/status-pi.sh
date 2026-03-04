#!/bin/bash
set -e

CLUSTER=$(terraform output -raw cluster_name)

TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING --profile personal-pi --query 'taskArns[]' --output text)

if [ -z "$TASK_ARNS" ]; then
  echo "No running tasks. Cost: \$0."
  exit 0
fi

echo "Running tasks:"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASK_ARNS --profile personal-pi \
  --query 'tasks[].{Task:taskArn,Status:lastStatus,Started:startedAt,CPU:cpu,Memory:memory}' \
  --output table
