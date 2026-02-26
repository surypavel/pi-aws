#!/bin/bash
set -e

CLUSTER=$(terraform output -raw cluster_name)
TASK_DEF=$(terraform output -raw task_definition)
SG=$(terraform output -raw security_group_id)
SUBNETS=$(terraform output -raw subnet_ids)

echo "Starting Pi agent..."
TASK_ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type FARGATE \
  --enable-execute-command \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
  --profile personal-pi \
  --query 'tasks[0].taskArn' --output text)

echo "Task: $TASK_ARN"
echo "Waiting for task to start..."
aws ecs wait tasks-running --cluster "$CLUSTER" --tasks "$TASK_ARN" --profile personal-pi

echo "Waiting for ECS Exec agent to initialize..."
for i in $(seq 1 30); do
  AGENT_STATUS=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --profile personal-pi \
    --query 'tasks[0].containers[0].managedAgents[?name==`ExecuteCommandAgent`].lastStatus' \
    --output text 2>/dev/null)
  if [ "$AGENT_STATUS" = "RUNNING" ]; then
    echo "ECS Exec agent is running."
    break
  fi
  echo "  Agent status: ${AGENT_STATUS:-not yet available} (attempt $i/30)"
  sleep 5
done

if [ "$AGENT_STATUS" != "RUNNING" ]; then
  echo "ERROR: ECS Exec agent did not start. Check CloudWatch logs."
  exit 1
fi

echo "Connecting... (run 'pi' to start the agent)"
aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ARN" \
  --container pi-agent \
  --interactive \
  --command "/bin/bash" \
  --profile personal-pi
