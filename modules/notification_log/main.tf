# Copyright 2026 Teak.io, Inc.
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

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.93, < 7"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2"
    }
  }
}

locals {
  lambda_name  = var.lambda_name
  log_group    = "/aws/lambda/${local.lambda_name}"
  logs_arn     = "arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.id}:log-group:${local.log_group}"
  iam_role_arn = coalesce(var.lambda_iam_role_arn, try(aws_iam_role.notification-log[0].arn))
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

data "aws_iam_policy_document" "lambda-logging" {
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

# Read-only, and it can't be scoped to a resource. The Lambda reads the BuildCommit tag of the
# AMI being deployed. Without this the notification still logs, just without a commit.
data "aws_iam_policy_document" "lambda-describe-images" {
  statement {
    actions   = ["ec2:DescribeImages"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "notification-log" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  name               = local.lambda_name
  assume_role_policy = data.aws_iam_policy_document.allow-lambda-assume.json

  description = "Role for the deploy notification logger. Only permissions should be logging and describing images."

  tags = local.tags
}

resource "aws_iam_policy" "lambda-logging" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  name   = "${local.lambda_name}LambdaLogging"
  policy = data.aws_iam_policy_document.lambda-logging.json

  description = "Allows logging to ${local.lambda_name} lambda log groups."

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "notification-log" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  role       = aws_iam_role.notification-log[count.index].name
  policy_arn = aws_iam_policy.lambda-logging[count.index].arn
}

resource "aws_iam_policy" "lambda-describe-images" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  name   = "${local.lambda_name}DescribeImages"
  policy = data.aws_iam_policy_document.lambda-describe-images.json

  description = "Allows ${local.lambda_name} to read the tags of the AMI being deployed."

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "notification-log-describe-images" {
  count = var.lambda_iam_role_arn == null ? 1 : 0

  role       = aws_iam_role.notification-log[count.index].name
  policy_arn = aws_iam_policy.lambda-describe-images[count.index].arn
}

# The notifications are this log group's contents, so the group is not optional.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.log_group
  retention_in_days = var.log_retention_in_days

  tags = local.tags
}

data "archive_file" "notification-log" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/notification_log.zip"
}

resource "aws_lambda_function" "notification-log" {
  function_name    = local.lambda_name
  role             = local.iam_role_arn
  architectures    = ["arm64"]
  memory_size      = 128
  runtime          = "ruby3.4"
  filename         = data.archive_file.notification-log.output_path
  source_code_hash = filebase64sha256(data.archive_file.notification-log.output_path)
  handler          = "notification_log.NotificationLog.handler"
  publish          = true

  timeout = 30

  environment {
    variables = {
      DEPLOY_SFN_ARN   = var.deploy_sfn.arn
      CANCEL_SFN_ARN   = var.cancel_sfn != null ? var.cancel_sfn.arn : ""
      UNDEPLOY_SFN_ARN = var.undeploy_sfn.arn
    }
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.notification-log,
    aws_iam_role_policy_attachment.notification-log-describe-images
  ]
}

# Same pattern as the slack_notifier rule, under its own name so both can live in one account.
resource "aws_cloudwatch_event_rule" "deploy-run" {
  name        = "${var.deploy_sfn.name}NotificationLog"
  description = "Matches all execution state changes on the deploy, undeploy and cancel state machines, to log them as deploy notifications"

  event_pattern = jsonencode({
    source      = ["aws.states"],
    detail-type = ["Step Functions Execution Status Change"],
    resources   = [for arn in compact([var.deploy_sfn.arn, var.undeploy_sfn.arn, var.cancel_sfn != null ? var.cancel_sfn.arn : null]) : { prefix = "${replace(arn, ":stateMachine:", ":execution:")}:" }]
  })

  tags = local.tags
}

resource "aws_lambda_permission" "deploy-run-invoke" {
  function_name = aws_lambda_function.notification-log.function_name

  action     = "lambda:InvokeFunction"
  principal  = "events.${data.aws_partition.current.dns_suffix}"
  source_arn = aws_cloudwatch_event_rule.deploy-run.arn
}

resource "aws_cloudwatch_event_target" "notification-log" {
  rule = aws_cloudwatch_event_rule.deploy-run.name
  arn  = aws_lambda_function.notification-log.arn
}

# Read access for whoever reads the notifications: one action on one log group.
data "aws_iam_policy_document" "reader-policy" {
  statement {
    actions   = ["logs:FilterLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_policy" "reader-policy" {
  name        = "${var.reader_role_name}Access"
  description = "Grants read access to the ${local.lambda_name} log group."
  policy      = data.aws_iam_policy_document.reader-policy.json

  tags = local.tags
}

data "aws_iam_policy_document" "allow-reader-assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for account_id in var.reader_account_ids : "arn:${data.aws_partition.current.partition}:iam::${account_id}:root"]
    }

    dynamic "condition" {
      for_each = var.external_id != null ? [1] : []

      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.external_id]
      }
    }
  }
}

resource "aws_iam_role" "reader" {
  name        = var.reader_role_name
  path        = "/${var.organization_prefix}/ci-service-role/"
  description = "Role to assume to read deploy notifications. Read-only."

  assume_role_policy = data.aws_iam_policy_document.allow-reader-assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "reader-policy" {
  role       = aws_iam_role.reader.name
  policy_arn = aws_iam_policy.reader-policy.arn
}
