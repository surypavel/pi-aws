# --- IAM Role for API Lambdas ---

resource "aws_iam_role" "api_lambda_role" {
  name = "PiApiLambdaRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_lambda_basic" {
  role       = aws_iam_role.api_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "api_lambda_policy" {
  name = "PiApiLambdaPolicy"
  role = aws_iam_role.api_lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      {
        # ECS: run / stop / list / describe tasks
        Action   = ["ecs:RunTask", "ecs:StopTask", "ecs:ListTasks", "ecs:DescribeTasks"],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        # iam:PassRole is required by ECS RunTask so it can assign roles to the new task
        Action   = "iam:PassRole",
        Effect   = "Allow",
        Resource = [
          aws_iam_role.ecs_execution_role.arn,
          aws_iam_role.pi_agent_role.arn,
        ]
      },
      {
        # CloudWatch: read logs for /logs endpoint
        Action   = ["logs:GetLogEvents", "logs:DescribeLogStreams"],
        Effect   = "Allow",
        Resource = "${aws_cloudwatch_log_group.pi_agent.arn}:*"
      },
    ]
  })
}

# --- Lambda package (all handlers share one zip) ---

data "archive_file" "api_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/api"
  output_path = "${path.module}/lambda_api.zip"
}

# Shared environment variables injected into every Lambda
locals {
  lambda_env = {
    ECS_CLUSTER         = aws_ecs_cluster.pi.name
    ECS_TASK_DEFINITION = aws_ecs_task_definition.pi_agent.family
    ECS_CONTAINER_NAME  = "pi-agent"
    ECS_SUBNETS         = join(",", data.aws_subnets.default.ids)
    ECS_SECURITY_GROUP  = aws_security_group.pi_agent.id
    LOG_GROUP           = aws_cloudwatch_log_group.pi_agent.name
  }
}

# --- Lambda functions ---

resource "aws_lambda_function" "api_start" {
  function_name    = "pi-api-start"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = "start.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.api_lambda.output_path
  source_code_hash = data.archive_file.api_lambda.output_base64sha256
  environment { variables = local.lambda_env }
}

resource "aws_lambda_function" "api_tasks" {
  function_name    = "pi-api-tasks"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = "tasks.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.api_lambda.output_path
  source_code_hash = data.archive_file.api_lambda.output_base64sha256
  environment { variables = local.lambda_env }
}

resource "aws_lambda_function" "api_logs" {
  function_name    = "pi-api-logs"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = "logs.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.api_lambda.output_path
  source_code_hash = data.archive_file.api_lambda.output_base64sha256
  environment { variables = local.lambda_env }
}

resource "aws_lambda_function" "api_stop" {
  function_name    = "pi-api-stop"
  role             = aws_iam_role.api_lambda_role.arn
  handler          = "stop.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.api_lambda.output_path
  source_code_hash = data.archive_file.api_lambda.output_base64sha256
  environment { variables = local.lambda_env }
}

# --- API Gateway (HTTP API v2) ---
# Stage is named "api" so routes are served at /api/{route}.
# CloudFront's /api/* behaviour forwards paths as-is, so /api/start hits
# the "api" stage which strips the prefix and routes to /start. No rewrite needed.

resource "aws_apigatewayv2_api" "pi" {
  name          = "pi-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.pi.id
  name        = "api"
  auto_deploy = true
}

# Integrations

resource "aws_apigatewayv2_integration" "start" {
  api_id                 = aws_apigatewayv2_api.pi.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_start.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "tasks" {
  api_id                 = aws_apigatewayv2_api.pi.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_tasks.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "logs" {
  api_id                 = aws_apigatewayv2_api.pi.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_logs.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "stop" {
  api_id                 = aws_apigatewayv2_api.pi.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_stop.invoke_arn
  payload_format_version = "2.0"
}

# Routes

resource "aws_apigatewayv2_route" "start" {
  api_id    = aws_apigatewayv2_api.pi.id
  route_key = "POST /start"
  target    = "integrations/${aws_apigatewayv2_integration.start.id}"
}

resource "aws_apigatewayv2_route" "tasks" {
  api_id    = aws_apigatewayv2_api.pi.id
  route_key = "GET /tasks"
  target    = "integrations/${aws_apigatewayv2_integration.tasks.id}"
}

resource "aws_apigatewayv2_route" "logs" {
  api_id    = aws_apigatewayv2_api.pi.id
  route_key = "GET /logs/{taskId}"
  target    = "integrations/${aws_apigatewayv2_integration.logs.id}"
}

resource "aws_apigatewayv2_route" "stop" {
  api_id    = aws_apigatewayv2_api.pi.id
  route_key = "POST /stop/{taskId}"
  target    = "integrations/${aws_apigatewayv2_integration.stop.id}"
}

# Lambda invoke permissions for API Gateway

resource "aws_lambda_permission" "api_start" {
  statement_id  = "AllowAPIGWInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_start.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.pi.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_tasks" {
  statement_id  = "AllowAPIGWInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_tasks.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.pi.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_logs" {
  statement_id  = "AllowAPIGWInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_logs.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.pi.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_stop" {
  statement_id  = "AllowAPIGWInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_stop.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.pi.execution_arn}/*/*"
}

# --- Output ---

output "api_gateway_url" {
  value       = aws_apigatewayv2_stage.api.invoke_url
  description = "Direct API Gateway URL (use CloudFront /api/* in production)"
}
