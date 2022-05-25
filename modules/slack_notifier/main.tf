# Copyright 2021 Teak.io, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3, < 5"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2"
    }
  }
}

locals {
  lambda_name  = var.lambda_name
  logs_arn     = "arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.id}:log-group:/aws/lambda/${local.lambda_name}"
  iam_role_arn = coalesce(var.lambda_iam_role_arn, try(aws_iam_role.slack-notify[0].arn))
  our_tags     = var.tags
  tags         = { for key, value in local.our_tags : key => value if lookup(data.aws_default_tags.tags.tags, key, null) != value }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_default_tags" "tags" {}

data "aws_iam_policy_document" "allow-lambda-assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

data "aws_iam_policy_document" "deployomat-lambda-logging" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups"
    ]

    resources = [
      local.logs_arn,
      "${local.logs_arn}:log-stream:*"
    ]
  }
}

resource "aws_iam_role" "slack-notify" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  name               = local.lambda_name
  assume_role_policy = data.aws_iam_policy_document.allow-lambda-assume.json

  description = "Role for the slack notifier. Only permissions should be logging."

  tags = local.tags
}

resource "aws_iam_policy" "deployomat-lambda-logging" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  name   = "${local.lambda_name}LambdaLogging"
  policy = data.aws_iam_policy_document.deployomat-lambda-logging.json

  description = "Allows logging to ${local.lambda_name} lambda log groups."

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "slack-notify" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  role       = aws_iam_role.slack-notify[count.index].name
  policy_arn = aws_iam_policy.deployomat-lambda-logging[count.index].arn
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = var.create_log_group ? 1 : 0

  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = var.log_retention_in_days

  tags = local.tags
}

data "archive_file" "slack-notify" {
  type        = "zip"
  source_file = coalesce(var.source_file, "${path.module}/src/slack_notify.rb")
  output_path = "${path.module}/build/slack_notify.zip"
}

resource "aws_lambda_function" "deployomat-slack-notify" {
  function_name    = local.lambda_name
  role             = local.iam_role_arn
  architectures    = ["arm64"]
  memory_size      = 128
  runtime          = "ruby2.7"
  filename         = data.archive_file.slack-notify.output_path
  source_code_hash = filebase64sha256(data.archive_file.slack-notify.output_path)
  handler          = "slack_notify.SlackNotify.handler"
  publish          = true

  timeout = 60

  environment {
    variables = {
      SLACK_CHANNEL    = var.slack_notification_channel
      SLACK_BOT_TOKEN  = var.slack_bot_token
      DEPLOY_SFN_ARN   = var.deploy_sfn.arn
      CANCEL_SFN_ARN   = var.cancel_sfn != null ? var.cancel_sfn.arn : ""
      UNDEPLOY_SFN_ARN = var.undeploy_sfn.arn
      UNDEPLOY_TECHNO  = var.techno ? "true" : "false"
      TECHNO_BEATS     = var.hot_techno_beats
    }
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.slack-notify
  ]
}

resource "aws_cloudwatch_event_rule" "deploy-run" {
  name        = "${var.deploy_sfn.name}Executions"
  description = var.cancel_sfn != null ? "Matches all execution state changes on ${var.deploy_sfn.name}, ${var.undeploy_sfn.name}, or ${var.cancel_sfn.name}" : "Matches all execution state changes on ${var.deploy_sfn.name} or ${var.undeploy_sfn.name}"

  event_pattern = jsonencode({
    source      = compact(["aws.states", var.custom_update_event_source]),
    detail-type = compact(["Step Functions Execution Status Change", var.custom_update_event_detail_type]),
    resources   = [ for arn in compact([var.deploy_sfn.arn, var.undeploy_sfn.arn, var.cancel_sfn != null ? var.cancel_sfn.arn : null]) : { prefix = "${replace(arn, ":stateMachine:", ":execution:")}:" } ]
  })

  tags = local.tags
}

resource "aws_lambda_permission" "deploy-run-invoke" {
  function_name = aws_lambda_function.deployomat-slack-notify.function_name

  action     = "lambda:InvokeFunction"
  principal  = "events.${data.aws_partition.current.dns_suffix}"
  source_arn = aws_cloudwatch_event_rule.deploy-run.arn
}

resource "aws_cloudwatch_event_target" "deploy-notify" {
  rule = aws_cloudwatch_event_rule.deploy-run.name
  arn  = aws_lambda_function.deployomat-slack-notify.arn
}
