#!/bin/bash
set -e

ECR_URL=$(terraform output -raw ecr_repo_url)
REGISTRY=$(echo "$ECR_URL" | cut -d'/' -f1)

echo "Authenticating Docker to ECR..."
aws ecr get-login-password --region eu-central-1 --profile personal-pi | \
  docker login --username AWS --password-stdin "$REGISTRY"

echo "Building image..."
docker build --platform linux/amd64 -t pi-agent .

echo "Pushing to $ECR_URL..."
docker tag pi-agent:latest "$ECR_URL:latest"
docker push "$ECR_URL:latest"

echo "Done."
