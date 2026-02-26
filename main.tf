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

# --- ECR Repository ---

resource "aws_ecr_repository" "pi_agent" {
  name         = "pi-agent"
  force_delete = true
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
        Resource = aws_lambda_function.git_bridge.arn
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

  container_definitions = jsonencode([{
    name      = "pi-agent"
    image     = "${aws_ecr_repository.pi_agent.repository_url}:latest"
    essential = true
    linuxParameters = {
      initProcessEnabled = true
    }
    environment = [
      { name = "AWS_REGION", value = "eu-central-1" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.pi_agent.name
        "awslogs-region"        = "eu-central-1"
        "awslogs-stream-prefix" = "pi"
      }
    }
  }])
}

# --- IAM: Lambda Execution Role ---

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

# --- Lambda Bridge ---

resource "aws_lambda_function" "git_bridge" {
  function_name    = "GitLab-Bridge"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = "lambda_function.zip"
  source_code_hash = filebase64sha256("lambda_function.zip")
}

# --- Outputs (used by start-pi.sh) ---

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
