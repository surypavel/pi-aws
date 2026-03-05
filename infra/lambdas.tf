# --- Agent Tool Lambdas ---
# Each tool gets its own block. Add a tool by copying an existing block,
# creating lambda/agent/<name>.py, and adding a matching entry to the SAM template below.

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

# --- coin_toss ---

data "archive_file" "coin_toss" {
  type        = "zip"
  source_file = "${path.module}/../lambda/agent/coin_toss.py"
  output_path = "${path.module}/../dist/lambda_agent_coin_toss.zip"
}

resource "aws_lambda_function" "coin_toss" {
  function_name    = "pi-agent-coin-toss"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "coin_toss.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.coin_toss.output_path
  source_code_hash = data.archive_file.coin_toss.output_base64sha256
}

# --- github_create_pull_request ---

resource "aws_secretsmanager_secret" "github_pr_token" {
  name = "pi-agent/github-pr-token"
}

data "archive_file" "github_create_pull_request" {
  type        = "zip"
  source_file = "${path.module}/../lambda/agent/github_create_pull_request.py"
  output_path = "${path.module}/../dist/lambda_agent_github_create_pull_request.zip"
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

resource "aws_iam_role_policy" "github_create_pull_request_secrets" {
  name = "PiLambdaGithubPrSecretsPolicy"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action   = "secretsmanager:GetSecretValue",
      Effect   = "Allow",
      Resource = aws_secretsmanager_secret.github_pr_token.arn
    }]
  })
}

# --- SAM template for local development ---
# Run `terraform apply`, then `sam local start-lambda` to invoke lambdas locally.
# Set AWS_ENDPOINT_URL_LAMBDA=http://localhost:3001 so `aws lambda invoke` in skills hits SAM.

resource "local_file" "sam_template" {
  filename = "${path.module}/../template.yaml"
  content = yamlencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Transform                = "AWS::Serverless-2016-10-31"
    Globals = {
      Function = {
        Runtime = "python3.12"
        CodeUri = "lambda/agent/"
      }
    }
    Resources = {
      CoinToss = {
        Type = "AWS::Serverless::Function"
        Properties = {
          FunctionName = aws_lambda_function.coin_toss.function_name
          Handler      = "coin_toss.handler"
        }
      }
      GithubCreatePullRequest = {
        Type = "AWS::Serverless::Function"
        Properties = {
          FunctionName = aws_lambda_function.github_create_pull_request.function_name
          Handler      = "github_create_pull_request.handler"
          Environment = {
            Variables = {
              GITHUB_TOKEN_SECRET_ARN = "local"
            }
          }
        }
      }
    }
  })
}

# --- Output ---

output "agent_tool_arns" {
  value = {
    coin_toss                  = aws_lambda_function.coin_toss.arn
    github_create_pull_request = aws_lambda_function.github_create_pull_request.arn
  }
  description = "ARNs of agent tool Lambdas Pi can invoke"
}
