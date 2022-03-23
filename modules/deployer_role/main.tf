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
  }
}

data "aws_partition" "current" {}
data "aws_default_tags" "tags" {}

locals {
  deployer_accessible_state_machines = [
    var.deploy_sfn_arn,
    var.cancel_sfn_arn,
    var.undeploy_sfn_arn
  ]

  our_tags = var.tags
  tags     = { for key, value in local.our_tags : key => value if lookup(data.aws_default_tags.tags.tags, key, null) != value }
}

data "aws_iam_policy_document" "deployer-policy" {
  statement {
    actions = [
      "states:DescribeStateMachine",
      "states:ListExecutions",
      "states:StartExecution"
    ]

    resources = local.deployer_accessible_state_machines
  }

  statement {
    actions = [
      "states:DescribeExecution",
      "states:DescribeStateMachineForExecution",
      "states:GetExecutionHistory"
    ]

    resources = [
      for arn in local.deployer_accessible_state_machines : "${replace(arn, ":stateMachine:", ":execution:")}:*"
    ]

  }

  statement {
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:GetLogGroupFields",
      "logs:ListTagsLogGroup",
    ]

    resources = flatten(
      concat(
        var.cloudwatch_log_group_arns,
        formatlist("%s:*", var.cloudwatch_log_group_arns)
      )
    )
  }
}

resource "aws_iam_policy" "deployer-policy" {
  name        = "DeployerAccess"
  description = "Grants access to state machines and logs necessary to run deploys."
  policy      = data.aws_iam_policy_document.deployer-policy.json
}

data "aws_iam_policy_document" "allow-meta-account-assume" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "AWS"
      identifiers = [for account_id in var.user_account_ids : "arn:${data.aws_partition.current.partition}:iam::${account_id}:root"]
    }
  }
}

resource "aws_iam_role" "deployer" {
  name        = var.role_name
  path        = "/${var.organization_prefix}/ci-service-role/"
  description = "Role to assume to manage deploys."

  assume_role_policy = data.aws_iam_policy_document.allow-meta-account-assume.json
}

resource "aws_iam_role_policy_attachment" "deployer-policy" {
  role       = aws_iam_role.deployer.name
  policy_arn = aws_iam_policy.deployer-policy.arn
}
