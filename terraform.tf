locals {
  domain_name = "members.bostondsa.org"
  stage_name  = "prod"

  tags = {
    App  = "members"
    Repo = "https://github.com/BostonDSA/members"
  }
}

terraform {
  backend s3 {
    bucket = "terraform.bostondsa.org"
    key    = "members.tfstate"
    region = "us-east-1"
  }

  required_version = "~> 0.13"
}

provider aws {
  region  = "us-east-1"
  version = "~> 3.1"
}

data aws_acm_certificate cert {
  domain   = var.acm_certificate_domain
  statuses = ["ISSUED"]
}

data aws_iam_policy basic {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data aws_iam_policy_document assume_role {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data aws_iam_policy_document inline {
  statement {
    sid       = "GetSecretValue"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.secret.arn]
  }

  statement {
    sid       = "PublishToSns"
    actions   = ["sns:Publish"]
    resources = [data.aws_sns_topic.slackbot.arn]
  }
}

data aws_secretsmanager_secret secret {
  name = "members"
}

data aws_sns_topic slackbot {
  name = "slack-socialismbot"
}

resource aws_api_gateway_domain_name domain {
  domain_name     = local.domain_name
  certificate_arn = data.aws_acm_certificate.cert.arn
}

resource aws_api_gateway_base_path_mapping base_path {
  api_id      = aws_api_gateway_rest_api.api.id
  domain_name = aws_api_gateway_domain_name.domain.domain_name
  stage_name  = aws_api_gateway_deployment.prod.stage_name
}

resource aws_api_gateway_deployment prod {
  depends_on = [
    aws_api_gateway_integration.get,
    aws_api_gateway_integration.proxy_any,
    aws_api_gateway_method.get,
    aws_api_gateway_method.proxy_any,
  ]
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = local.stage_name
}

resource aws_api_gateway_integration get {
  content_handling        = "CONVERT_TO_TEXT"
  http_method             = aws_api_gateway_method.get.http_method
  integration_http_method = "POST"
  resource_id             = aws_api_gateway_rest_api.api.root_resource_id
  rest_api_id             = aws_api_gateway_rest_api.api.id
  timeout_milliseconds    = 29000
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.lambda.invoke_arn
}

resource aws_api_gateway_integration proxy_any {
  content_handling        = "CONVERT_TO_TEXT"
  http_method             = aws_api_gateway_method.proxy_any.http_method
  integration_http_method = "POST"
  resource_id             = aws_api_gateway_resource.proxy.id
  rest_api_id             = aws_api_gateway_rest_api.api.id
  timeout_milliseconds    = 29000
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.lambda.invoke_arn
}

resource aws_api_gateway_method get {
  authorization = "NONE"
  http_method   = "GET"
  resource_id   = aws_api_gateway_rest_api.api.root_resource_id
  rest_api_id   = aws_api_gateway_rest_api.api.id
}

resource aws_api_gateway_method proxy_any {
  authorization = "NONE"
  http_method   = "ANY"
  resource_id   = aws_api_gateway_resource.proxy.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
}

resource aws_api_gateway_resource proxy {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "{proxy+}"
}

resource aws_api_gateway_rest_api api {
  description = "Member portal"
  name        = var.api_name
}

resource aws_cloudwatch_log_group logs {
  name              = "/aws/lambda/${aws_lambda_function.lambda.function_name}"
  retention_in_days = 30
  tags              = local.tags
}

resource aws_iam_role role {
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  name               = "members"
}

resource aws_iam_role_policy inline {
  name   = "members"
  policy = data.aws_iam_policy_document.inline.json
  role   = aws_iam_role.role.name
}

resource aws_iam_role_policy_attachment basic {
  policy_arn = data.aws_iam_policy.basic.arn
  role       = aws_iam_role.role.name
}

resource aws_lambda_function lambda {
  description      = "Member portal"
  filename         = "${path.module}/package.zip"
  function_name    = var.lambda_function_name
  handler          = "lambda.handler"
  memory_size      = 2048
  role             = aws_iam_role.role.arn
  runtime          = "nodejs12.x"
  source_code_hash = filebase64sha256("${path.module}/package.zip")
  tags             = local.tags
  timeout          = 29

  environment {
    variables = {
      AWS_SECRET      = data.aws_secretsmanager_secret.secret.name
      HOST            = "https://${local.domain_name}"
      SLACK_TOPIC_ARN = data.aws_sns_topic.slackbot.arn
    }
  }
}

resource aws_lambda_permission invoke {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*/*"
}

variable api_name {
  description = "API Gateway REST API name"
  default     = "members"
}

variable acm_certificate_domain {
  description = "ACM certificate domain"
  default     = "members.bostondsa.org"
}

variable lambda_function_name {
  description = "Lambda function name"
  default     = "members"
}

output url {
  description = "App URL"
  value       = "https://${aws_api_gateway_domain_name.domain.domain_name}/"
}
