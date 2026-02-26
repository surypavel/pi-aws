Warning: This is generated completely by LLMs and is being iterated on. 

# AWS Cloud Coding Factory: Setup Guide (2026)

This guide covers the end-to-end setup for running an autonomous coding agent (like **Pi**) on a secure AWS infrastructure using **Terraform**, **Bedrock**, and **ECS Fargate** (scales to zero when idle).

## Table of Contents

1. Local Tooling (Mac)
2. AWS Profile Management
3. Bedrock Model Access
4. Deploy the Infrastructure (Terraform)
5. Agent Deployment (Pi)

---

## 1. Local Tooling (Mac)

Install the industry-standard CLIs using Homebrew.

```bash
# Install AWS CLI
brew install awscli

# Install Terraform
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Session Manager plugin (needed for interactive ECS Exec)
# Homebrew cask was deprecated (unsigned binary). Use AWS's signed .pkg instead:
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg" -o "session-manager-plugin.pkg"
sudo installer -pkg session-manager-plugin.pkg -target /
sudo ln -s /usr/local/sessionmanagerplugin/bin/session-manager-plugin /usr/local/bin/session-manager-plugin
rm session-manager-plugin.pkg

# Verify installations
aws --version
terraform -version
session-manager-plugin --version
```

---

## 2. AWS Profile Management

Since you have work credentials, we will use a **Named Profile** for your personal project to keep them isolated.

```bash
# 1. First-time only: log in to https://console.aws.amazon.com and create
#    a root access key (top-right → Security credentials → Create access key).
#    Configure a temporary profile with it:
aws configure --profile personal-root

# 2. Create an IAM user with CLI access (do NOT use root keys long-term):
aws iam create-user --user-name pi-deployer --profile personal-root

# 3. Attach a scoped-down policy (see pi-deployer-policy.json for the full list):
aws iam create-policy --policy-name PiDeployerPolicy \
  --policy-document file://pi-deployer-policy.json --profile personal-root
aws iam attach-user-policy --user-name pi-deployer \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/PiDeployerPolicy \
  --profile personal-root

# 4. Create access keys for the IAM user:
aws iam create-access-key --user-name pi-deployer --profile personal-root
# ^ Save the AccessKeyId and SecretAccessKey from the output

# 5. Configure your project profile with the IAM user keys:
aws configure --profile personal-pi
# When prompted, paste the IAM user's Access Key ID, Secret, region 'eu-central-1', output 'json'

# 6. Delete the root access key (you no longer need it):
#    Go to https://console.aws.amazon.com → Security credentials → Delete the root key
#    Or: aws iam delete-access-key --access-key-id <ROOT_KEY_ID> --profile personal-root

# 7. Verify you are using the correct account
aws sts get-caller-identity --profile personal-pi

# (Optional) Set this as the default for your current terminal session
export AWS_PROFILE=personal-pi
```

---

### Updating the IAM policy

When [`pi-deployer-policy.json`](pi-deployer-policy.json) changes, update it using root credentials (the deployer cannot modify its own policy):

```bash
POLICY_ARN=$(aws iam list-policies --scope Local --profile personal-root \
  --query 'Policies[?PolicyName==`PiDeployerPolicy`].Arn' --output text)
aws iam create-policy-version --policy-arn "$POLICY_ARN" \
  --policy-document file://pi-deployer-policy.json \
  --set-as-default --profile personal-root
```

> **Note:** IAM policies can have at most 5 versions. If you hit the limit, delete old versions first:
> `aws iam list-policy-versions --policy-arn "$POLICY_ARN" --profile personal-root`
> `aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id <OLD_VERSION> --profile personal-root`

---

## 3. Bedrock Model Access

We use **Amazon Nova Micro** — Amazon's cheapest Bedrock model. Since it's a first-party Amazon model, it requires **no additional enablement or legal forms**. IAM permissions (handled by Terraform below) are all you need.

To verify access:

```bash
echo '{"messages":[{"role":"user","content":[{"text":"Say hello"}]}]}' > /tmp/bedrock-test.json
aws bedrock-runtime invoke-model \
  --model-id eu.amazon.nova-micro-v1:0 \
  --content-type application/json \
  --accept application/json \
  --body fileb:///tmp/bedrock-test.json \
  --profile personal-pi \
  /dev/stdout
```

If you get a JSON response with the model's reply, you're good to go.

---

## 4. Deploy the Infrastructure (Terraform)

The infrastructure is defined in [`main.tf`](main.tf). It uses ECS Fargate so you **only pay while the agent is running** — no idle EC2 costs.

It provisions:
- ECS service-linked role (required on first use in an account)
- Default VPC networking and a security group (outbound-only)
- ECR repository for the agent Docker image
- ECS cluster and Fargate task definition
- IAM roles for ECS task execution, agent permissions (Bedrock, Lambda, ECS Exec), and Lambda
- CloudWatch log group (7-day retention)
- Lambda function (Git bridge) — the handler is in [`lambda/index.py`](lambda/index.py), which will eventually hold your GitLab/Jira tokens
- Optional monthly budget alerts and cost anomaly detection ([`budget.tf`](budget.tf), configured via [`variables.tf`](variables.tf))

### Steps to deploy

Run these commands in order:

```bash
# 1. Package the Lambda code (Terraform needs this zip to exist before apply)
zip -j lambda_function.zip lambda/index.py

# 2. Initialize Terraform (first time only — downloads the AWS provider)
terraform init

# 3. Preview what will be created
terraform plan

# 4. Create all resources (VPC, ECR, ECS, IAM, Lambda, CloudWatch — everything in one go)
terraform apply
```

After `terraform apply` completes, Terraform will print output values (ECR URL, cluster name, etc.) that are used in the next steps.

---

## 5. Agent Deployment (Pi)

### Dockerfile

The container is defined in [`Dockerfile`](Dockerfile). It includes [`models.json`](models.json) (adds the EU inference profile model to the built-in Bedrock provider), [`settings.json`](settings.json) (sets Nova Micro EU as default), and [`watchdog.sh`](watchdog.sh) (auto-stops the container after inactivity). The image is built for `linux/amd64` (required by Fargate).

The AWS CLI v2 is installed in the container image so you can call AWS services (e.g., Lambda) directly from the interactive shell. An alternative would be to use the Node.js AWS SDK (`@aws-sdk/client-lambda`, ~5MB), but the full CLI (~150MB) was chosen for convenience — it supports ad-hoc debugging (`aws logs tail`, `aws s3 cp`, etc.) without writing scripts. Both approaches use the same ECS task role credentials from the metadata endpoint; no security difference.

### Build and Push to ECR

Use [`build-push.sh`](build-push.sh) to build the Docker image and push it to ECR:

```bash
chmod +x build-push.sh
./build-push.sh
```

### Run on Demand

Use [`start-pi.sh`](start-pi.sh) to launch the agent:

```bash
chmod +x start-pi.sh
./start-pi.sh

# Inside the container, Pi starts with Nova Micro (EU) by default:
pi

# The container auto-stops after 10 min of inactivity (no pi/node process).
# Grace period: 30 min after startup to give you time to connect.
```

### Calling Lambda from Inside the Container

The ECS task role (`PiAgentRole`) grants `lambda:InvokeFunction` on the `GitLab-Bridge` function. From inside the container:

```bash
aws lambda invoke \
  --function-name GitLab-Bridge \
  --payload '{"action": "test"}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

No credentials or profile needed — the container automatically gets the task role via the ECS metadata endpoint.

### Monitor and Stop

```bash
# Check if anything is running
./status-pi.sh

# Manually stop all running tasks
./stop-pi.sh
```

Scripts: [`start-pi.sh`](start-pi.sh) | [`stop-pi.sh`](stop-pi.sh) | [`status-pi.sh`](status-pi.sh) | [`build-push.sh`](build-push.sh)
