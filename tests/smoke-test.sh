#!/usr/bin/env bash
# Smoke test against the live deployment.
# Usage:  API_PASSWORD=pipi ./tests/smoke-test.sh
#
# API_URL and FRONTEND_URL are read from `terraform output` if not set explicitly.

set -euo pipefail

cd "$(dirname "$0")/.."

FRONTEND_URL="${FRONTEND_URL:-$(terraform -chdir=infra output -raw frontend_url)}"
API_URL="${API_URL:-${FRONTEND_URL}/api}"
API_PASSWORD="${API_PASSWORD:-pipi}"
CREDS="pi:${API_PASSWORD}"

PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc  (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Smoke test ==="
echo "Frontend : $FRONTEND_URL"
echo "API      : $API_URL"
echo ""

# 1. GET /api/tasks → 200
status=$(curl -s -o /dev/null -w "%{http_code}" -u "$CREDS" "$API_URL/tasks")
check "GET /api/tasks → 200" "200" "$status"

# 2. POST /api/start with empty body → 400
status=$(curl -s -o /dev/null -w "%{http_code}" -u "$CREDS" \
  -X POST -H "Content-Type: application/json" -d '{}' "$API_URL/start")
check "POST /api/start (empty) → 400" "400" "$status"

# 3. GET /api/logs/nonexistent → 200 with lines array
body=$(curl -s -u "$CREDS" "$API_URL/logs/nonexistent-task-id")
has_lines=$(echo "$body" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('yes' if isinstance(d.get('lines'), list) else 'no')" 2>/dev/null || echo "no")
check "GET /api/logs/nonexistent → 200 + lines[]" "yes" "$has_lines"

# 4. GET frontend without credentials → 401
status=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL")
check "GET frontend (no creds) → 401" "401" "$status"

# 5. GET frontend with credentials → 200
status=$(curl -s -o /dev/null -w "%{http_code}" -u "$CREDS" "$FRONTEND_URL")
check "GET frontend (with creds) → 200" "200" "$status"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
