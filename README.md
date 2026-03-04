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

# Create a least-privilege IAM user for deployments
aws iam create-user --user-name pi-deployer --profile personal-root
aws iam create-policy --policy-name PiDeployerPolicy \
  --policy-document file://pi-deployer-policy.json --profile personal-root
aws iam attach-user-policy --user-name pi-deployer \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/PiDeployerPolicy \
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

### Updating the IAM policy

```bash
POLICY_ARN=$(aws iam list-policies --scope Local --profile personal-root \
  --query 'Policies[?PolicyName==`PiDeployerPolicy`].Arn' --output text)
aws iam create-policy-version --policy-arn "$POLICY_ARN" \
  --policy-document file://pi-deployer-policy.json \
  --set-as-default --profile personal-root
```

> IAM policies allow at most 5 versions. Delete old ones if needed:
> `aws iam list-policy-versions --policy-arn "$POLICY_ARN" --profile personal-root`

---

## 3. Bedrock Model Access

Pi uses **Amazon Nova Micro** (EU inference profile) — Amazon's cheapest Bedrock model, no opt-in forms required.

```bash
echo '{"messages":[{"role":"user","content":[{"text":"Say hello"}]}]}' > /tmp/test.json
aws bedrock-runtime invoke-model \
  --model-id eu.amazon.nova-micro-v1:0 \
  --content-type application/json --accept application/json \
  --body fileb:///tmp/test.json \
  --profile personal-pi /dev/stdout
```

---

## 4. Deploy the Infrastructure (Terraform)

The infrastructure is split across several `.tf` files:

| File | What it creates |
|---|---|
| [`main.tf`](main.tf) | VPC, security group, ECR repos, ECS cluster & task definition, IAM roles (`PiEcsExecutionRole`, `PiAgentRole`), CloudWatch log group, Secrets Manager secret, `GitLab-Bridge` Lambda |
| [`frontend.tf`](frontend.tf) | S3 bucket, CloudFront OAC, CloudFront distribution, CloudFront Function (Basic Auth), CloudFront `/api/*` behaviour, S3 upload of `index.html` |
| [`api.tf`](api.tf) | `PiApiLambdaRole`, four API Lambda functions, API Gateway HTTP API (stage `api`) |
| [`budget.tf`](budget.tf) | Optional monthly budget alerts and cost anomaly detection |
| [`variables.tf`](variables.tf) | `ui_password`, `enable_budget`, `budget_limit`, `budget_alert_email` |

### Steps

```bash
# 1. Create terraform.tfvars (gitignored — never commit this)
cat > terraform.tfvars <<'EOF'
ui_password = "your-secure-password"
EOF

# 2. Package the GitLab-Bridge Lambda (Terraform needs the zip to exist on first apply)
zip -j lambda_function.zip lambda/index.py

# 3. First-time init (downloads the AWS provider)
terraform init

# 4. Preview
terraform plan

# 5. Deploy everything
terraform apply

# 6. Print the frontend URL
terraform output frontend_url
```

> `lambda_api.zip` (the API backend) is built automatically by Terraform's `archive_file`
> data source — you do not need to zip it manually.

CloudFront distributions take **5–10 minutes** to create on first deploy; subsequent updates take **2–5 minutes**.

---

## 5. Build and Push the Agent Image

The container entry point ([`entrypoint.sh`](entrypoint.sh)) has two modes:

| Condition | Behaviour |
|---|---|
| `PROMPT` env var is set | `pi --print "$PROMPT" --no-session` — headless, exits when done |
| `PROMPT` is not set | Falls back to [`watchdog.sh`](watchdog.sh) — interactive, auto-stops after 10 min idle |

The frontend always sets `PROMPT` via ECS container overrides. The interactive fallback exists so `start-pi.sh` still works for debugging sessions.

```bash
chmod +x build-push.sh
./build-push.sh
```

This builds a `linux/amd64` image (required by Fargate) and pushes it to ECR. Run it after any change to the `Dockerfile`, `entrypoint.sh`, or files copied into the image.

---

## 6. Web Frontend & API

### Access

```
URL:      terraform output -raw frontend_url
Username: pi
Password: value of ui_password in terraform.tfvars
```

The browser shows its native Basic Auth dialog. The same credential protects every `/api/*` call — no separate auth in the Lambda code.

### How it works

- **[`frontend/index.html`](frontend/index.html)** — single-page app; `const API = "/api"` calls the same CloudFront domain, so no CORS is needed
- **[`frontend.tf`](frontend.tf)** — S3 + CloudFront for the HTML; `etag = filemd5(...)` triggers automatic re-upload when the file changes; `/api/*` behaviour proxies to API Gateway
- **[`api.tf`](api.tf)** — four Lambda functions sharing one zip + API Gateway HTTP API; stage named `api` so `/api/start` routes to the `POST /start` handler without any URL rewriting
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
| `PiLambdaExecRole` | `GitLab-Bridge` (tool called *by* Pi from inside ECS) | Basic execution only |
| `PiApiLambdaRole` | API Lambdas (called *by* API Gateway from outside) | ECS ops + `iam:PassRole` + CloudWatch read |

`PiAgentRole` (the ECS task role) grants `lambda:InvokeFunction` on `GitLab-Bridge` — Pi can call its tools, but has no access to the API Lambdas.

### Redeploy after changes

```bash
# After changing Lambda code or index.html:
terraform apply

# After changing the Docker image:
./build-push.sh && terraform apply
```

---

## 7. Running Pi Interactively (optional)

For debugging sessions — opens an ECS Exec shell into a running container:

```bash
./start-pi.sh    # launches a task and connects via ECS Exec

# Inside the container:
pi               # interactive Pi session (watchdog auto-stops after 10 min idle)

# Call the GitLab-Bridge Lambda directly:
aws lambda invoke \
  --function-name GitLab-Bridge \
  --payload '{"action": "test"}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

No credentials needed inside the container — it automatically gets the `PiAgentRole` credentials via the ECS metadata endpoint.

```bash
./status-pi.sh   # list running tasks
./stop-pi.sh     # stop all running tasks
```

> Requires the Session Manager plugin from section 1.

---

## 8. Testing

### Unit tests

```bash
pip install pytest   # one-time
pytest tests/test_lambdas.py -v
```

Tests all four handlers with `unittest.mock` — no AWS credentials or network access needed.

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

`API_URL` and `FRONTEND_URL` are read from `terraform output` if not set explicitly.
