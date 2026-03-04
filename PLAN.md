# pi-aws: Implementation Plan

Current state: frontend deployed at `terraform output frontend_url`, protected by HTTP Basic Auth, but all API calls silently fail (no backend yet).

---

## Step 1 — Headless container mode

**File:** `Dockerfile`, new `entrypoint.sh`

Replace `CMD ["/watchdog.sh"]` with a new `entrypoint.sh`:

```bash
if [ -n "$PROMPT" ]; then
  exec pi --print "$PROMPT" --no-session   # headless, exits when done
else
  exec /watchdog.sh                        # fallback: interactive via start-pi.sh
fi
```

The `PROMPT` env var is injected at `ECS RunTask` time via container overrides (Step 2).
After this, rebuild and push the image: `./build-push.sh`.

---

## Step 2 — Lambda functions

**New directory:** `lambda/api/`

Four handlers + shared helpers:

| File | Route | Action |
|---|---|---|
| `common.py` | — | `ok()`, `err()` response helpers |
| `start.py` | `POST /start` | `ECS RunTask` with `PROMPT` env override; returns `taskId`, `logStream` |
| `tasks.py` | `GET /tasks` | `ECS ListTasks` (RUNNING + last 20 STOPPED) + `DescribeTasks`; reads prompt back from task overrides |
| `logs.py` | `GET /logs/{taskId}` | `CloudWatch GetLogEvents` with `nextToken` for incremental polling; also returns task `status` |
| `stop.py` | `POST /stop/{taskId}` | `ECS StopTask` |

Log stream name is deterministic: `pi/pi-agent/{taskId}` (matches the `awslogs-stream-prefix = "pi"` in the task definition).

All functions share one zip (`data "archive_file"` over `lambda/api/`).

---

## Step 3 — API Gateway + CloudFront wiring

**New file:** `api.tf`

### API Gateway (HTTP API v2)

- `aws_apigatewayv2_api` with CORS `allow_origins = ["*"]`
- `$default` stage with auto-deploy
- Four Lambda integrations + routes (`POST /start`, `GET /tasks`, `GET /logs/{taskId}`, `POST /stop/{taskId}`)
- Lambda permissions for API Gateway invoke

### IAM role for API Lambdas (`PiApiLambdaRole`)

Needs:
- `AWSLambdaBasicExecutionRole` (CloudWatch logging)
- `ecs:RunTask`, `ecs:StopTask`, `ecs:ListTasks`, `ecs:DescribeTasks`
- `iam:PassRole` on `PiEcsExecutionRole` and `PiAgentRole` (required by `RunTask`)
- `logs:GetLogEvents`, `logs:DescribeLogStreams` on `/ecs/pi-coding-agent`

### CloudFront `/api/*` behaviour (Option B auth)

Add a second origin to the existing CloudFront distribution pointing at API Gateway, with a cache behaviour for `/api/*` that:
- Forwards `Authorization` header (so the Basic Auth CloudFront Function protects the API too)
- Disables caching
- Uses the same `basic_auth` function association

This means the frontend calls `/api/start` (same origin, no CORS), and CloudFront proxies it to API Gateway. The Lambdas no longer need their own auth check.

### Wire the frontend

Replace `const API = "";` in `index.html` with `const API = "${api_url}";` via `templatefile()`, where `api_url` is the CloudFront URL + `/api` prefix. Terraform re-uploads `index.html` to S3 automatically.

---

## Step 4 — Testing

### Unit tests (`tests/test_lambdas.py`)

`pytest` + `unittest.mock` — mock boto3 clients directly (no moto needed):

- Auth: each handler returns 200 (auth is now at CF level, no check in Lambda)
- `start`: mock `ecs.run_task` → verify `taskId` extracted from ARN, `logStream` format
- `start`: missing prompt → 400
- `tasks`: mock `list_tasks` + `describe_tasks` → verify prompt extracted from overrides, datetime formatting
- `logs`: mock `get_log_events` → verify lines returned, `nextToken` forwarded; mock `ResourceNotFoundException` → 200 with empty lines
- `stop`: mock `stop_task` → 200

### Smoke test (`tests/smoke-test.sh`)

Shell script to run against the live deployment — closes the feedback loop during development:

```bash
API_PASSWORD=pipi ./tests/smoke-test.sh
```

Checks:
1. `GET /api/tasks` → 200 (proves auth + Lambda + ECS list all work)
2. `POST /api/start` with empty body → 400 (proves validation works)
3. `GET /api/logs/nonexistent` → 200 with empty lines (proves graceful handling)
4. `GET {frontend_url}` without credentials → 401 (proves CF auth is on)
5. `GET {frontend_url}` with credentials → 200 (proves page is served)

Both `API_URL` and `FRONTEND_URL` are read from `terraform output` if not set explicitly.

---

## Decisions already made

| Topic | Decision |
|---|---|
| Execution mode | Headless only (`pi --print`); `start-pi.sh` still works as interactive fallback |
| Concurrency | One task at a time for now; `tasks.py` lists all and UI shows a kill button — trivially scales |
| Auth | HTTP Basic Auth at CloudFront edge; no auth logic in Lambda code |
| Log viewing | Poll `CloudWatch GetLogEvents` via Lambda with `nextToken`; 3 s interval while RUNNING |
| Frontend hosting | S3 + CloudFront (already deployed) |
| API routing | Through CloudFront (`/api/*` behaviour) — same origin, no CORS, one auth mechanism |
| Prompt passing | ECS container env override (`PROMPT`) — safe from shell injection, no image rebuild needed per prompt |
| Sessions | `--no-session` flag — no state persisted (EFS is a future concern) |
