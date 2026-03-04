#!/bin/bash
set -e

CLUSTER=$(terraform output -raw cluster_name)

TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING --profile personal-pi --query 'taskArns[]' --output text)

if [ -z "$TASK_ARNS" ]; then
  echo "No running tasks."
  exit 0
fi

for ARN in $TASK_ARNS; do
  echo "Stopping $ARN..."
  aws ecs stop-task --cluster "$CLUSTER" --task "$ARN" --profile personal-pi --no-cli-pager > /dev/null
done

echo "Done. Cost returns to \$0."
