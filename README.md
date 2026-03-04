# pi-aws: Cloud Coding Agent on AWS

Run [**Pi**](https://github.com/badlogic/pi-mono) as a headless coding agent on AWS ECS Fargate. Submit a prompt from a password-protected web UI, watch the logs stream in real time, kill runaway tasks. Scales to zero — you pay only while Pi is running.

---

## Architecture

```
Browser
  → CloudFront (HTTP Basic Auth at edge)
      → S3                  GET /*           serves index.html
      → API Gateway /api/*
            POST /start      Lambda → ECS RunTask  (injects PROMPT env var)
            GET  /tasks      Lambda → ECS ListTasks + DescribeTasks
            GET  /logs/{id}  Lambda → CloudWatch GetLogEvents  (incremental)
            POST /stop/{id}  Lambda → ECS StopTask
                                ↓
                          ECS Fargate task
                          pi --print "$PROMPT" --no-session
                          logs → CloudWatch /ecs/pi-coding-agent
                          tool calls → agent tool Lambdas
                                         pi-agent-gitlab-bridge
                                         pi-agent-jira-bridge
                                         (add more in lambda/agent/)
```

One password protects both the HTML page and every API call — enforced by a CloudFront Function before any request reaches an origin.

---

## Table of Contents

1. [Local Tooling (Mac)](#1-local-tooling-mac)
2. [AWS Profile Management](#2-aws-profile-management)
3. [Bedrock Model Access](#3-bedrock-model-access)
4. [Deploy the Infrastructure (Terraform)](#4-deploy-the-infrastructure-terraform)
5. [Build and Push the Agent Image](#5-build-and-push-the-agent-image)
6. [Web Frontend & API](#6-web-frontend--api)
7. [Running Pi Interactively (optional)](#7-running-pi-interactively-optional)
8. [Testing](#8-testing)

---

## 1. Local Tooling (Mac)

```bash
# AWS CLI
brew install awscli

# Terraform
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Session Manager plugin (only needed for interactive ECS Exec — see section 7)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg" \
  -o session-manager-plugin.pkg
sudo installer -pkg session-manager-plugin.pkg -target /
sudo ln -s /usr/local/sessionmanagerplugin/bin/session-manager-plugin /usr/local/bin/
rm session-manager-plugin.pkg

# Verify
aws --version && terraform -version
```

---

## 2. AWS Profile Management

Use a named profile to keep personal credentials separate from work credentials.

```bash
# First time: log in to the AWS Console and create a root access key, then:
aws configure --profile personal-root

# Create an IAM user for deployments (AdministratorAccess — fine for prototyping)
aws iam create-user --user-name pi-deployer --profile personal-root
aws iam attach-user-policy --user-name pi-deployer \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
  --profile personal-root

# Create access keys for the IAM user
aws iam create-access-key --user-name pi-deployer --profile personal-root
# ^ Save the AccessKeyId and SecretAccessKey

# Configure the project profile
aws configure --profile personal-pi
# region: eu-central-1  output: json

# Delete the root access key (no longer needed)
# AWS Console → Security credentials → Delete root key

# Verify
aws sts get-caller-identity --profile personal-pi

# Optional: set as default for the session
export AWS_PROFILE=personal-pi
```

---

## 3. Bedrock Model Access

Pi uses **Claude Haiku 4.5** (EU cross-region inference profile). Anthropic models on Bedrock require a one-time use-case form: open the **Bedrock console → Model catalog**, find Claude Haiku 4.5, and submit the form. Approval is usually instant.

```bash
echo '{"messages":[{"role":"user","content":[{"text":"Say hello"}]}]}' > /tmp/test.json
aws bedrock-runtime invoke-model \
  --model-id eu.anthropic.claude-haiku-4-5-20251001-v1:0 \
  --content-type application/json --accept application/json \
  --body fileb:///tmp/test.json \
  --profile personal-pi /dev/stdout
```

---

## 4. Deploy the Infrastructure (Terraform)

The infrastructure is split across several `.tf` files:

| File | What it creates |
|---|---|
| [`infra/main.tf`](infra/main.tf) | VPC, security group, ECR repos, ECS cluster & task definition, IAM roles (`PiEcsExecutionRole`, `PiAgentRole`), CloudWatch log group, Secrets Manager secrets, agent tool Lambdas (`pi-agent-jira-bridge`, `pi-agent-github-create-pull-request`) |
| [`infra/frontend.tf`](infra/frontend.tf) | S3 bucket, CloudFront OAC, CloudFront distribution, CloudFront Function (Basic Auth), CloudFront `/api/*` behaviour, S3 upload of `index.html` |
| [`infra/api.tf`](infra/api.tf) | `PiApiLambdaRole`, four API Lambda functions, API Gateway HTTP API (stage `api`) |
| [`infra/budget.tf`](infra/budget.tf) | Optional monthly budget alerts and cost anomaly detection |
| [`infra/variables.tf`](infra/variables.tf) | `ui_password`, `enable_budget`, `budget_limit`, `budget_alert_email` |

### Steps

```bash
# 1. Create terraform.tfvars (gitignored — never commit this)
cat > infra/terraform.tfvars <<'EOF'
ui_password = "your-secure-password"
EOF

# 2. First-time init (downloads the AWS provider)
terraform -chdir=infra init

# 3. Preview
terraform -chdir=infra plan

# 4. Deploy everything
terraform -chdir=infra apply

# 5. Store the GitHub token for the PR tool
#    Fine-grained PAT permissions required: Contents (read), Pull requests (read/write), Metadata (read)
aws secretsmanager put-secret-value \
  --secret-id pi-agent/github-pr-token \
  --secret-string "ghp_your_token_here" \
  --profile personal-pi

# 6. Print the frontend URL
terraform -chdir=infra output frontend_url
```

> All Lambda zips (`lambda_api.zip`, `lambda_agent_*.zip`) are built automatically by
> Terraform's `archive_file` data source — you do not need to zip anything manually.

CloudFront distributions take **5–10 minutes** to create on first deploy; subsequent updates take **2–5 minutes**.

---

## 5. Build and Push the Agent Image

The container entry point ([`entrypoint.sh`](entrypoint.sh)) has two modes:

| Condition | Behaviour |
|---|---|
| `PROMPT` env var is set | `pi --print "$PROMPT" --no-session` — headless, exits when done |
| `PROMPT` is not set | Falls back to [`watchdog.sh`](watchdog.sh) — interactive, auto-stops after 10 min idle |

The frontend always sets `PROMPT` via ECS container overrides. The interactive fallback exists so `scripts/start-pi.sh` still works for debugging sessions.

```bash
chmod +x scripts/build-push.sh
./scripts/build-push.sh
```

This builds a `linux/amd64` image (required by Fargate) and pushes it to ECR. Run it after any change to the [`Dockerfile`](Dockerfile), [`entrypoint.sh`](entrypoint.sh), or files copied into the image.

---

## 6. Web Frontend & API

### Access

```
URL:      terraform -chdir=infra output -raw frontend_url
Username: pi
Password: value of ui_password in infra/terraform.tfvars
```

The browser shows its native Basic Auth dialog. The same credential protects every `/api/*` call — no separate auth in the Lambda code.

### How it works

- **[`frontend/index.html`](frontend/index.html)** — single-page app; `const API = "/api"` calls the same CloudFront domain, so no CORS is needed
- **[`infra/frontend.tf`](infra/frontend.tf)** — S3 + CloudFront for the HTML; `etag = filemd5(...)` triggers automatic re-upload when the file changes; `/api/*` behaviour proxies to API Gateway
- **[`infra/api.tf`](infra/api.tf)** — four Lambda functions sharing one zip + API Gateway HTTP API; stage named `api` so `/api/start` routes to the `POST /start` handler without any URL rewriting
- **[`lambda/api/`](lambda/api/)** — Python 3.12 handlers

### Lambda handlers

| File | Route | What it does |
|---|---|---|
| [`start.py`](lambda/api/start.py) | `POST /api/start` | ECS `RunTask`, injects `PROMPT` as env var override |
| [`tasks.py`](lambda/api/tasks.py) | `GET /api/tasks` | Lists RUNNING + last 20 STOPPED tasks, extracts prompts from overrides |
| [`logs.py`](lambda/api/logs.py) | `GET /api/logs/{taskId}` | CloudWatch `GetLogEvents` with `nextToken` for incremental polling; also returns task status |
| [`stop.py`](lambda/api/stop.py) | `POST /api/stop/{taskId}` | ECS `StopTask` |

Log stream names are deterministic: `pi/pi-agent/{taskId}` (derived from `awslogs-stream-prefix = "pi"` in the task definition), so `logs.py` can fetch them directly without a lookup.

### IAM separation

Two distinct Lambda roles — the trust flows are opposite:

| Role | Used by | Permissions |
|---|---|---|
| `PiLambdaExecRole` | Agent tool Lambdas (tools called *by* Pi from inside ECS) | Basic execution only |
| `PiApiLambdaRole` | API Lambdas (called *by* API Gateway from outside) | ECS ops + `iam:PassRole` + CloudWatch read |

`PiAgentRole` (the ECS task role) grants `lambda:InvokeFunction` on all agent tool Lambdas — Pi can call its tools, but has no access to the API Lambdas.

### Redeploy after changes

```bash
# After changing Lambda code or index.html:
terraform -chdir=infra apply

# After changing the Docker image:
./scripts/build-push.sh && terraform -chdir=infra apply
```

---

## 7. Running Pi Interactively (optional)

For debugging sessions — opens an ECS Exec shell into a running container:

```bash
./scripts/start-pi.sh    # launches a task and connects via ECS Exec

# Inside the container:
pi               # interactive Pi session (watchdog auto-stops after 10 min idle)

# Call an agent tool Lambda directly:
aws lambda invoke \
  --function-name pi-agent-gitlab-bridge \
  --payload '{"action": "test", "project": "myorg/myrepo"}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout

aws lambda invoke \
  --function-name pi-agent-jira-bridge \
  --payload '{"action": "create_issue", "issue_key": "PI-1"}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

No credentials needed inside the container — it automatically gets the `PiAgentRole` credentials via the ECS metadata endpoint.

```bash
./scripts/status-pi.sh   # list running tasks
./scripts/stop-pi.sh     # stop all running tasks
```

> Requires the Session Manager plugin from section 1.

---

## 8. Testing

### Unit tests

```bash
pip install pytest   # one-time

# API Lambda handlers (start, tasks, logs, stop)
pytest tests/test_lambdas.py -v

# Agent tool Lambda handlers (gitlab_bridge, jira_bridge)
pytest tests/test_agent_tools.py -v

# Run all tests together
pytest tests/ -v
```

All tests use `unittest.mock` — no AWS credentials or network access needed.

### Adding a new agent tool

1. Create `lambda/agent/<tool_name>.py` with a `handler(event, context)` function.
2. Add `"<tool_name>"` to the `agent_tools` set in [`infra/main.tf`](infra/main.tf).
3. Add tests to [`tests/test_agent_tools.py`](tests/test_agent_tools.py).
4. Run `terraform -chdir=infra apply` — Terraform zips and deploys the new Lambda automatically.

### Smoke test (against live deployment)

```bash
API_PASSWORD=your-password ./tests/smoke-test.sh
```

Checks (all via the live CloudFront URL):

1. `GET /api/tasks` → 200
2. `POST /api/start` with empty body → 400
3. `GET /api/logs/nonexistent` → 200 with empty `lines` array
4. Frontend without credentials → 401
5. Frontend with credentials → 200

`API_URL` and `FRONTEND_URL` are read from `terraform -chdir=infra output` if not set explicitly.
