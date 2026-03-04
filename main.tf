provider "aws" {
  region  = "eu-central-1"
  profile = "personal-pi"
}

# --- ECS Service-Linked Role (required on first use in an account) ---

resource "aws_iam_service_linked_role" "ecs" {
  aws_service_name = "ecs.amazonaws.com"
}

# --- Networking (Default VPC) ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "pi_agent" {
  name        = "pi-agent-sg"
  description = "Outbound-only access for Pi agent"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ECR Repositories ---

resource "aws_ecr_repository" "pi_agent" {
  name         = "pi-agent"
  force_delete = true
}

resource "aws_ecr_repository" "git_proxy" {
  name         = "pi-git-proxy"
  force_delete = true
}

# --- Secrets Manager ---

# GitHub PAT for git proxy (injected into the git-proxy container at runtime)
resource "aws_secretsmanager_secret" "github_token" {
  name = "pi-agent/github-token"
}

# GitHub PAT for the github_create_pull_request Lambda tool
# The ECS task role (PiAgentRole) has NO access to this secret — only the Lambda execution role does.
resource "aws_secretsmanager_secret" "github_pr_token" {
  name = "pi-agent/github-pr-token"
}

# --- ECS Cluster ---

resource "aws_ecs_cluster" "pi" {
  name = "pi-coding-cluster"
}

# --- IAM: ECS Task Execution Role (pull images, push logs) ---

resource "aws_iam_role" "ecs_execution_role" {
  name = "PiEcsExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "EcsExecutionSecretsPolicy"
  role = aws_iam_role.ecs_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action   = "secretsmanager:GetSecretValue",
      Effect   = "Allow",
      Resource = aws_secretsmanager_secret.github_token.arn
    }]
  })
}

# --- IAM: Agent Task Role (Bedrock, Lambda, ECS Exec) ---

resource "aws_iam_role" "pi_agent_role" {
  name = "PiAgentRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "pi_permissions" {
  name = "PiAgentPolicy"
  role = aws_iam_role.pi_agent_role.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      {
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Effect   = "Allow",
        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0",
          "arn:aws:bedrock:*:*:inference-profile/eu.amazon.nova-micro-v1:0"
        ]
      },
      {
        Action   = "lambda:InvokeFunction",
        Effect   = "Allow",
        Resource = concat(
          [for k, v in aws_lambda_function.agent_tool : v.arn],
          [aws_lambda_function.github_create_pull_request.arn],
        )
      },
      {
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

# --- CloudWatch Logs ---

resource "aws_cloudwatch_log_group" "pi_agent" {
  name              = "/ecs/pi-coding-agent"
  retention_in_days = 7
}

# --- ECS Task Definition ---

resource "aws_ecs_task_definition" "pi_agent" {
  family                   = "pi-coding-agent"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.pi_agent_role.arn

  container_definitions = jsonencode([
    {
      name      = "pi-agent"
      image     = "${aws_ecr_repository.pi_agent.repository_url}:latest"
      essential = true
      linuxParameters = {
        initProcessEnabled = true
      }
      environment = [
        { name = "AWS_REGION", value = "eu-central-1" }
      ]
      dependsOn = [
        { containerName = "git-proxy", condition = "HEALTHY" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.pi_agent.name
          "awslogs-region"        = "eu-central-1"
          "awslogs-stream-prefix" = "pi"
        }
      }
    },
    {
      name      = "git-proxy"
      image     = "${aws_ecr_repository.git_proxy.repository_url}:latest"
      essential = true
      secrets = [
        { name = "GITHUB_TOKEN", valueFrom = aws_secretsmanager_secret.github_token.arn }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/healthz || exit 1"]
        interval    = 5
        timeout     = 2
        retries     = 3
        startPeriod = 5
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.pi_agent.name
          "awslogs-region"        = "eu-central-1"
          "awslogs-stream-prefix" = "git-proxy"
        }
      }
    }
  ])
}

# --- IAM: Lambda Execution Role (agent tools called by Pi) ---

resource "aws_iam_role" "lambda_exec_role" {
  name = "PiLambdaExecRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow Lambda tools to read their own secrets (ECS task role has no access to these)
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "PiLambdaSecretsPolicy"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action   = "secretsmanager:GetSecretValue",
      Effect   = "Allow",
      Resource = aws_secretsmanager_secret.github_pr_token.arn
    }]
  })
}

# --- Agent Tool Lambdas ---
# Add a simple tool by adding its name to this set and creating lambda/agent/<name>.py

locals {
  agent_tools = toset(["coin_toss"])
}

data "archive_file" "agent_tool" {
  for_each    = local.agent_tools
  type        = "zip"
  source_file = "${path.module}/lambda/agent/${each.key}.py"
  output_path = "${path.module}/dist/lambda_agent_${each.key}.zip"
}

resource "aws_lambda_function" "agent_tool" {
  for_each         = local.agent_tools
  function_name    = "pi-agent-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "${each.key}.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.agent_tool[each.key].output_path
  source_code_hash = data.archive_file.agent_tool[each.key].output_base64sha256
}

# --- github_create_pull_request (dedicated — needs secret access) ---

data "archive_file" "github_create_pull_request" {
  type        = "zip"
  source_file = "${path.module}/lambda/agent/github_create_pull_request.py"
  output_path = "${path.module}/dist/lambda_agent_github_create_pull_request.zip"
}

resource "aws_lambda_function" "github_create_pull_request" {
  function_name    = "pi-agent-github-create-pull-request"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "github_create_pull_request.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.github_create_pull_request.output_path
  source_code_hash = data.archive_file.github_create_pull_request.output_base64sha256
  environment {
    variables = {
      GITHUB_TOKEN_SECRET_ARN = aws_secretsmanager_secret.github_pr_token.arn
    }
  }
}

# --- Outputs (used by scripts/start-pi.sh) ---

output "ecr_repo_url" {
  value = aws_ecr_repository.pi_agent.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.pi.name
}

output "task_definition" {
  value = aws_ecs_task_definition.pi_agent.family
}

output "subnet_ids" {
  value = join(",", data.aws_subnets.default.ids)
}

output "security_group_id" {
  value = aws_security_group.pi_agent.id
}

output "git_proxy_ecr_repo_url" {
  value = aws_ecr_repository.git_proxy.repository_url
}

output "agent_tool_arns" {
  value = merge(
    { for k, v in aws_lambda_function.agent_tool : k => v.arn },
    { github_create_pull_request = aws_lambda_function.github_create_pull_request.arn },
  )
  description = "ARNs of agent tool Lambdas Pi can invoke"
}
