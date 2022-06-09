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
  required_version = ">= 1.1"

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

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_default_tags" "tags" {}

locals {
  service     = var.deployomat_service_name
  environment = var.environment

  lambda_log_arns = flatten(
    concat(
      values(aws_cloudwatch_log_group.lambda)[*].arn,
      formatlist("%s:*", values(aws_cloudwatch_log_group.lambda)[*].arn)
    )
  )

  our_tags = merge(var.tags, { Service = local.service, Environment = local.environment })
  tags     = { for key, value in local.our_tags : key => value if lookup(data.aws_default_tags.tags.tags, key, null) != value }

  ami_owner_account_ids = join(",", coalesce(var.ami_owner_account_ids, [data.aws_caller_identity.current.id]))
}

resource "aws_dynamodb_table" "state" {
  name           = local.service
  hash_key       = "id"
  billing_mode   = "PAY_PER_REQUEST"
  stream_enabled = false

  attribute {
    name = "id"
    type = "S"
  }
}

data "aws_iam_policy_document" "deployomat-lambda-logging" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups"
    ]

    resources = local.lambda_log_arns
  }
}

resource "aws_iam_policy" "deployomat-lambda-logging" {
  name   = "DeployomatLambdaLogging"
  policy = data.aws_iam_policy_document.deployomat-lambda-logging.json

  description = "Allows logging to ${local.service} lambda log groups."

  tags = local.tags
}

locals {
  automatic_undeploy_rule_arn = "arn:${data.aws_partition.current.partition}:events:*:${data.aws_caller_identity.current.account_id}:rule/*-automatic-undeploy"
}

data "aws_iam_policy_document" "deployomat-lambda" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    resources = [var.deployomat_meta_role_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = ["&{aws:PrincipalTag/Environment}"]
    }

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "sts:TransitiveTagKeys"
      values   = ["Environment"]
    }
  }

  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    resources = ["arn:${data.aws_partition.current.partition}:iam::*:role/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["&{aws:PrincipalTag/Environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = [local.service]
    }
  }

  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem"
    ]

    resources = [
      aws_dynamodb_table.state.arn,
      "${aws_dynamodb_table.state.arn}/*"
    ]
  }

  statement {
    actions = [
      "events:PutRule",
      "events:TagResource"
    ]

    resources = [local.automatic_undeploy_rule_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = ["&{aws:PrincipalTag/Environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Managed"
      values   = [local.service]
    }
  }

  statement {
    actions = [
      "events:RemoveTargets",
      "events:DeleteRule"
    ]

    resources = [local.automatic_undeploy_rule_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["&{aws:PrincipalTag/Environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Managed"
      values   = [local.service]
    }
  }

  statement {
    actions = [
      "events:PutTargets"
    ]

    resources = [local.automatic_undeploy_rule_arn]

    # I would desperately love to have ABAC control here to ensure that this policy only permits
    # putting targets on rules which are managed by local.service. However, in testing, IAM appeared
    # to need a _significant_ delay to actually see the tags on the new rule. The API could see them
    # immediately, just not IAM. So... here we are.

    # condition {
    #   test = "StringEquals"
    #   variable = "aws:ResourceTag/Environment"
    #   values = ["&{aws:PrincipalTag/Environment}"]
    # }

    # condition {
    #   test = "StringEquals"
    #   variable = "aws:ResourceTag/Managed"
    #   values = [local.service]
    # }

    condition {
      test     = "ForAllValues:ArnEquals"
      variable = "events:TargetArn"
      values   = [aws_sfn_state_machine.undeploy.arn]
    }
  }

  statement {
    actions = [
      "events:DescribeRule"
    ]

    resources = [local.automatic_undeploy_rule_arn]
  }

  statement {
    actions = [
      "iam:PassRole"
    ]

    resources = [aws_iam_role.automatic-undeployer.arn]

    condition {
      test     = "ArnLike"
      variable = "iam:AssociatedResourceArn"
      values   = [local.automatic_undeploy_rule_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["events.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_policy" "deployomat-lambda" {
  name   = "DeployomatLambda"
  policy = data.aws_iam_policy_document.deployomat-lambda.json

  description = "Allows deployomat lambdas to log, manage state, and assume roles in other accounts."

  tags = local.tags
}

data "aws_iam_policy_document" "allow-lambda-assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "deployomat" {
  name               = local.service
  assume_role_policy = data.aws_iam_policy_document.allow-lambda-assume.json

  description = "Role for deployomat lambdas to assume"

  tags = local.tags
}

data "aws_iam_policy_document" "allow-events-assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

data "aws_iam_policy_document" "allow-invoke-undeploy" {
  statement {
    actions = ["states:StartExecution"]

    resources = [aws_sfn_state_machine.undeploy.arn]
  }
}

resource "aws_iam_policy" "allow-invoke-undeploy" {
  name   = "AutomaticUndployer"
  policy = data.aws_iam_policy_document.allow-invoke-undeploy.json

  description = "Allows invoking the undeploy state machine."

  tags = local.tags
}

resource "aws_iam_role" "automatic-undeployer" {
  name               = "${local.service}-AutomaticUndeployer"
  assume_role_policy = data.aws_iam_policy_document.allow-events-assume.json

  description = "Role for EventBridge to assume to invoke the undeploy step function"

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "allow-invoke-undeploy" {
  role       = aws_iam_role.automatic-undeployer.name
  policy_arn = aws_iam_policy.allow-invoke-undeploy.arn
}

moved {
  from = aws_iam_role_policy_attachment.deployomat["logging"]
  to   = aws_iam_role_policy_attachment.deployomat-logging
}

moved {
  from = aws_iam_role_policy_attachment.deployomat["deploy"]
  to   = aws_iam_role_policy_attachment.deployomat-deploy
}

resource "aws_iam_role_policy_attachment" "deployomat-logging" {
  role       = aws_iam_role.deployomat.name
  policy_arn = aws_iam_policy.deployomat-lambda-logging.arn
}

resource "aws_iam_role_policy_attachment" "deployomat-deploy" {
  role       = aws_iam_role.deployomat.name
  policy_arn = aws_iam_policy.deployomat-lambda.arn
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = toset(["DeployomatCancel", "DeployomatDeploy", "DeployomatUndeploy"])

  name              = "/aws/lambda/${each.key}"
  retention_in_days = var.log_retention_in_days

  tags = local.tags
}

data "archive_file" "deployomat" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "deployomat-cancel" {
  function_name    = "DeployomatCancel"
  role             = aws_iam_role.deployomat.arn
  architectures    = ["arm64"]
  memory_size      = 512
  runtime          = "ruby2.7"
  filename         = data.archive_file.deployomat.output_path
  source_code_hash = filebase64sha256(data.archive_file.deployomat.output_path)
  handler          = "lambda_handlers.LambdaFunctions::Handler.cancel"
  publish          = true

  timeout = 60

  environment {
    variables = {
      DEPLOYOMAT_META_ROLE_ARN = var.deployomat_meta_role_arn,
      DEPLOYOMAT_ENV           = local.environment,
      DEPLOYOMAT_TABLE         = aws_dynamodb_table.state.name
      DEPLOYOMAT_SERVICE_NAME  = local.service
      ROLE_EXTERNAL_ID         = var.external_id
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.deployomat-logging,
    aws_cloudwatch_log_group.lambda
  ]
}

resource "aws_lambda_function" "deployomat-deploy" {
  function_name    = "DeployomatDeploy"
  role             = aws_iam_role.deployomat.arn
  architectures    = ["arm64"]
  memory_size      = 512
  runtime          = "ruby2.7"
  filename         = data.archive_file.deployomat.output_path
  source_code_hash = filebase64sha256(data.archive_file.deployomat.output_path)
  handler          = "lambda_handlers.LambdaFunctions::Handler.deploy"
  publish          = true

  timeout = 60

  environment {
    variables = {
      DEPLOYOMAT_META_ROLE_ARN = var.deployomat_meta_role_arn
      DEPLOYOMAT_ENV           = local.environment
      DEPLOYOMAT_TABLE         = aws_dynamodb_table.state.name
      DEPLOYOMAT_SERVICE_NAME  = local.service
      UNDEPLOY_SFN_ARN         = aws_sfn_state_machine.undeploy.arn
      UNDEPLOYER_ROLE_ARN      = aws_iam_role.automatic-undeployer.arn
      DEPLOYOMAT_AMI_SEARCH_OWNERS = local.ami_owner_account_ids
      ROLE_EXTERNAL_ID         = var.external_id
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.deployomat-logging,
    aws_cloudwatch_log_group.lambda
  ]
}

resource "aws_lambda_function" "deployomat-undeploy" {
  function_name    = "DeployomatUndeploy"
  role             = aws_iam_role.deployomat.arn
  architectures    = ["arm64"]
  memory_size      = 512
  runtime          = "ruby2.7"
  filename         = data.archive_file.deployomat.output_path
  source_code_hash = filebase64sha256(data.archive_file.deployomat.output_path)
  handler          = "lambda_handlers.LambdaFunctions::Handler.undeploy"
  publish          = true

  timeout = 60

  environment {
    variables = {
      DEPLOYOMAT_META_ROLE_ARN = var.deployomat_meta_role_arn,
      DEPLOYOMAT_ENV           = local.environment,
      DEPLOYOMAT_TABLE         = aws_dynamodb_table.state.name
      DEPLOYOMAT_SERVICE_NAME  = local.service
      ROLE_EXTERNAL_ID         = var.external_id
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.deployomat-logging,
    aws_cloudwatch_log_group.lambda
  ]
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/${var.organization_prefix}/${local.environment}/deployomat-sfn"
  retention_in_days = var.log_retention_in_days
}

# Taken from https://web.archive.org/web/20220127185530/https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-and-resource-policy.html
# N.B. At time of writing this snapshot wasn't yet live, and contains modifications from the
# 2021 snapshot.
# I have no idea why AWS insists on working this way.
data "aws_iam_policy_document" "aws-log-delivery" {
  statement {
    sid    = "AWSLogDeliveryWrite20150319"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${aws_cloudwatch_log_group.sfn.arn}:*"
    ]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.${data.aws_partition.current.dns_suffix}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "deployomat-logging" {
  policy_document = data.aws_iam_policy_document.aws-log-delivery.json
  policy_name     = "deployomat-states-logging-policy"
}

data "aws_iam_policy_document" "allow-sfn-assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

# I hate this, but it came from https://web.archive.org/web/20220120061359/https://docs.aws.amazon.com/step-functions/latest/dg/cw-logs.html
# We manage the resource policy ourselves at least so we don't have to grant this role permission to make
# arbitrary changes to logging resource policies (and by extension give arbitrary things arbitrary access to logs),
# but all of the other permissions appear to still be required.
data "aws_iam_policy_document" "deployomat-sfn" {
  statement {
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups"
    ]

    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "states:StartExecution"
    ]

    resources = ["arn:${data.aws_partition.current.partition}:states:*:${data.aws_caller_identity.current.id}:stateMachine:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = [local.service]
    }
  }

  statement {
    actions = [
      "states:DescribeExecution",
      "states:StopExecution"
    ]

    resources = ["*"]
  }

  statement {
    actions = [
      "events:PutTargets",
      "events:PutRule",
      "events:DescribeRule"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:events:*:${data.aws_caller_identity.current.id}:rule/StepFunctionsGetEventsForStepFunctionsExecutionRule"
    ]
  }
}

data "aws_iam_policy_document" "deployomat-sfn-lambda-invoke" {
  statement {
    actions = [
      "lambda:InvokeFunction"
    ]

    resources = [
      aws_lambda_function.deployomat-cancel.arn,
      aws_lambda_function.deployomat-deploy.arn,
      aws_lambda_function.deployomat-undeploy.arn
    ]
  }
}

resource "aws_iam_policy" "deployomat-sfn" {
  name   = "DeployomatStates"
  policy = data.aws_iam_policy_document.deployomat-sfn.json

  description = "Allows deployomat state machines to invoke other state machines, cloudwatch events, and log."

  tags = local.tags
}

resource "aws_iam_policy" "deployomat-sfn-lambda-invoke" {
  name   = "DeployomatStates-LambdaInvoke"
  policy = data.aws_iam_policy_document.deployomat-sfn-lambda-invoke.json

  description = "Allows deployomat state machines to invoke lambdas."

  tags = local.tags
}

resource "aws_iam_role" "deployomat-sfn" {
  name               = "DeployomatStates"
  assume_role_policy = data.aws_iam_policy_document.allow-sfn-assume.json

  description = "Role for deployomat state machines (AWS Step Functions) to assume."

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "deployomat-sfn" {
  role       = aws_iam_role.deployomat-sfn.name
  policy_arn = aws_iam_policy.deployomat-sfn.arn
}

resource "aws_iam_role_policy_attachment" "deployomat-sfn-lambda-invoke" {
  role       = aws_iam_role.deployomat-sfn.name
  policy_arn = aws_iam_policy.deployomat-sfn-lambda-invoke.arn
}

resource "aws_sfn_state_machine" "cancel-deploy" {
  name     = "Deployomat-CancelDeploy"
  role_arn = aws_iam_role.deployomat-sfn.arn
  definition = templatefile(
    "${path.module}/state_machines/cancel.json",
    {
      cancel_lambda_arn = aws_lambda_function.deployomat-cancel.arn
    }
  )

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_resource_policy.deployomat-logging,
    aws_iam_role_policy_attachment.deployomat-sfn
  ]
}

resource "aws_sfn_state_machine" "loop-wait-state" {
  name     = "Deployomat-LoopWaitState"
  role_arn = aws_iam_role.deployomat-sfn.arn
  definition = templatefile(
    "${path.module}/state_machines/loop-wait.json",
    {
      deploy_lambda_arn = aws_lambda_function.deployomat-deploy.arn
    }
  )

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_resource_policy.deployomat-logging,
    aws_iam_role_policy_attachment.deployomat-sfn
  ]
}

resource "aws_sfn_state_machine" "deploy" {
  name     = "Deployomat-Deploy"
  role_arn = aws_iam_role.deployomat-sfn.arn
  definition = templatefile(
    "${path.module}/state_machines/deploy.json",
    {
      deploy_lambda_arn                 = aws_lambda_function.deployomat-deploy.arn,
      loop_wait_state_state_machine_arn = aws_sfn_state_machine.loop-wait-state.arn,
      cancel_deploy_state_machine_arn   = aws_sfn_state_machine.cancel-deploy.arn
    }
  )

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_resource_policy.deployomat-logging,
    aws_iam_role_policy_attachment.deployomat-sfn
  ]
}

resource "aws_sfn_state_machine" "undeploy" {
  name     = "Deployomat-Undeploy"
  role_arn = aws_iam_role.deployomat-sfn.arn
  definition = templatefile(
    "${path.module}/state_machines/undeploy.json",
    {
      undeploy_lambda_arn             = aws_lambda_function.deployomat-undeploy.arn,
      cancel_deploy_state_machine_arn = aws_sfn_state_machine.cancel-deploy.arn
    }
  )

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_resource_policy.deployomat-logging,
    aws_iam_role_policy_attachment.deployomat-sfn
  ]
}
