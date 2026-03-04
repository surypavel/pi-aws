#!/usr/bin/env bash
# Run pi locally in Docker, mounting the repo's .pi/ config folder.
# Self-extending changes to AGENTS.md persist back into .pi/ (version-controlled).
# Assumes PiAgentRole via STS to mirror ECS permissions exactly.
#
# Usage:
#   ./scripts/run-local.sh                               # interactive pi in current directory
#   ./scripts/run-local.sh /path/to/project              # interactive pi in a specific project
#   PI_PROMPT="Fix the auth bug" ./scripts/run-local.sh  # headless one-shot mode
#
# Prerequisites:
#   - Docker running
#   - AWS credentials configured (default profile: personal-pi)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${1:-$(pwd)}"
IMAGE="pi-local"
AWS_PROFILE="personal-pi"

if [ -n "${PI_PROMPT:-}" ]; then
  PI_CMD=(pi --print "$PI_PROMPT" --no-session)
else
  PI_CMD=(pi)
fi

echo "Building image..."
docker build --platform linux/arm64 -t "$IMAGE" "$REPO_DIR"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/PiAgentRole"
echo "Assuming ${ROLE_ARN}..."
CREDS=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name pi-local \
  --profile "$AWS_PROFILE" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)

echo "Starting pi..."
docker run -it --rm \
  -e AWS_ACCESS_KEY_ID="$(echo "$CREDS" | awk '{print $1}')" \
  -e AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | awk '{print $2}')" \
  -e AWS_SESSION_TOKEN="$(echo "$CREDS" | awk '{print $3}')" \
  -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}" \
  -v "$REPO_DIR/.pi":/root/.pi/agent \
  -v "$WORKSPACE":/workspace \
  -w /workspace \
  "$IMAGE" "${PI_CMD[@]}"
