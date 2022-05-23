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

locals {
  default_service_tag = lookup(data.aws_default_tags.tags.tags, "Service", null)
  our_tags            = merge(var.tags, { Service = var.deployomat_service_name })
  tags                = { for key, value in local.our_tags : key => value if lookup(data.aws_default_tags.tags.tags, key, null) != value }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_default_tags" "tags" {}

# Allow any role named var.primary_role_name in var.ci_cd_accounts
# to assume our role, conditioned on
# 1. The Environment tag on the role in this account must match the Environment tag
#    on the role in the CI/CD account.
# 2. The Service tag on the primary role must be set to var.deployomat_service_name
data "aws_iam_policy_document" "allow-deployomat-assume" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    principals {
      type        = "AWS"
      identifiers = formatlist("arn:${data.aws_partition.current.partition}:iam::%s:root", var.ci_cd_account_ids)
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["&{aws:PrincipalTag/Environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/Service"
      values   = [var.deployomat_service_name]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["ServiceName", "ServiceLogName"]
    }
  }
}

# Allow reading config/* and roles/var.deployomat_service_name for any account
# in the primary role's environment, _or_ for _any_ account if the primary role's
# environment is production.
data "aws_iam_policy_document" "allow-deploy" {
  statement {
    actions = [
      "autoscaling:CreateAutoScalingGroup",
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Managed"
      values   = [var.deployomat_service_name]
    }
  }

  statement {
    actions = [
      "autoscaling:DeleteAutoScalingGroup",
      "autoscaling:AttachLoadBalancerTargetGroups",
      "autoscaling:PutScalingPolicy",
      "autoscaling:PutWarmPool",
      "autoscaling:UpdateAutoScalingGroup"
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Managed"
      values   = [var.deployomat_service_name]
    }
  }

  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLoadBalancerTargetGroups",
      "autoscaling:DescribePolicies",
      "autoscaling:DescribeTags",
      "autoscaling:DescribeWarmPool",
      "autoscaling:DescribeLifecycleHooks",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages"
    ]

    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "ec2:CreateLaunchTemplateVersion",
      "ec2:ModifyLaunchTemplate"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.id}:launch-template/*"
    ]
  }

  statement {
    actions = [
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteRule"
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Managed"
      values   = [var.deployomat_service_name]
    }
  }

  statement {
    actions = [
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:CreateTargetGroup"
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Managed"
      values   = [var.deployomat_service_name]
    }
  }

  statement {
    actions = [
      "elasticloadbalancing:DeleteTargetGroup",
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Managed"
      values   = [var.deployomat_service_name]
    }
  }

  statement {
    actions = [
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeTargetHealth"
    ]

    resources = [
      "*"
    ]
  }

  statement {
    actions = [
      "iam:PassRole"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.id}:role/aws-service-role/autoscaling.amazonaws.com/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["autoscaling.amazonaws.com"]
    }
  }

  statement {
    actions = [
      "iam:PassRole"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.id}:role/${var.organization_prefix}/service-role/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }

    condition {
      test     = "Bool"
      variable = "aws:ViaAWSService"
      values   = ["true"]
    }
  }

  statement {
    actions = [
      "ec2:RunInstances",
      # https://web.archive.org/web/20201112013446/https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/elb-api-permissions.html
      # Apparently ElasticLoadBalancing needs these
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      # This is needed for launch templates which have tags on them
      "ec2:CreateTags",
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:ViaAWSService"
      values   = ["true"]
    }
  }

  statement {
    actions = [
      "logs:FilterLogEvents"
    ]

    resources = [
      "arn:aws:logs:*:*:log-group:/${var.organization_prefix}/server/&{aws:PrincipalTag/Environment}/service/&{aws:PrincipalTag/ServiceLogName}:log-stream:",
      "arn:aws:logs:*:*:log-group:/${var.organization_prefix}/server/&{aws:PrincipalTag/Environment}/service/&{aws:PrincipalTag/ServiceLogName}/*:log-stream:",
    ]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalTag/ServiceLogName"
      values   = ["?*"]
    }
  }
}

resource "aws_iam_policy" "allow-deploy" {
  name   = "Allow${title(var.deployomat_service_name)}DeployAccess"
  policy = data.aws_iam_policy_document.allow-deploy.json

  description = "Allows ${var.deployomat_service_name} to manage deployments in this account."

  tags = local.tags
}

resource "aws_iam_role" "role" {
  name               = "${title(var.deployomat_service_name)}DeployAccess"
  assume_role_policy = data.aws_iam_policy_document.allow-deployomat-assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "allow-deploy" {
  role       = aws_iam_role.role.name
  policy_arn = aws_iam_policy.allow-deploy.arn
}
