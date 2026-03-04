#!/usr/bin/env bash
# Run pi locally in Docker, mounting the repo's .pi/ config folder.
# Self-extending changes to AGENTS.md persist back into .pi/ (version-controlled).
#
# Usage:
#   ./run-local.sh                               # interactive pi in current directory
#   ./run-local.sh /path/to/project              # interactive pi in a specific project
#   PI_PROMPT="Fix the auth bug" ./run-local.sh  # headless one-shot mode
#
# Prerequisites:
#   - Docker running
#   - AWS credentials configured for Bedrock (default profile: personal-pi)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${1:-$(pwd)}"
IMAGE="pi-local"
AWS_PROFILE="${AWS_PROFILE:-personal-pi}"

if [ -n "${PI_PROMPT:-}" ]; then
  PI_CMD=(pi --print "$PI_PROMPT" --no-session)
else
  PI_CMD=(pi)
fi

echo "Building image..."
docker build --platform linux/arm64 -t "$IMAGE" "$REPO_DIR"

echo "Starting pi..."
docker run -it --rm \
  -v "$HOME/.aws":/root/.aws:ro \
  --tmpfs /root/.aws/cli/cache \
  -v "$REPO_DIR/.pi":/root/.pi/agent \
  -v "$WORKSPACE":/workspace \
  -w /workspace \
  -e AWS_PROFILE="$AWS_PROFILE" \
  -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}" \
  "$IMAGE" "${PI_CMD[@]}"
