#!/bin/bash
set -e

ECR_URL=$(terraform output -raw ecr_repo_url)
PROXY_ECR_URL=$(terraform output -raw git_proxy_ecr_repo_url)
REGISTRY=$(echo "$ECR_URL" | cut -d'/' -f1)

echo "Authenticating Docker to ECR..."
aws ecr get-login-password --region eu-central-1 --profile personal-pi | \
  docker login --username AWS --password-stdin "$REGISTRY"

echo "Building pi-agent image..."
docker build --platform linux/amd64 -t pi-agent .

echo "Pushing pi-agent to $ECR_URL..."
docker tag pi-agent:latest "$ECR_URL:latest"
docker push "$ECR_URL:latest"

echo "Building git-proxy image..."
docker build --platform linux/amd64 -t git-proxy ./git-proxy

echo "Pushing git-proxy to $PROXY_ECR_URL..."
docker tag git-proxy:latest "$PROXY_ECR_URL:latest"
docker push "$PROXY_ECR_URL:latest"

echo "Done."
