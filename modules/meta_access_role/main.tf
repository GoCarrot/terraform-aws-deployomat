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
  our_tags = merge(var.tags, { Service = var.deployomat_service_name })
  tags     = { for key, value in local.our_tags : key => value if lookup(data.aws_default_tags.tags.tags, key, null) != value }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_default_tags" "tags" {}

# Allow anyone in var.ci_cd_accounts
# to assume our role, conditioned on
# 1. An Environment tag must be passed as a session tag, and it must
#    be set to the value of the Environment tag on the source principal
# 2. The Environment tag must be marked as transitive
# 3. The Service tag on the source principal must be set to var.deployomat_service_name
data "aws_iam_policy_document" "allow-deployomat-assume" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "AWS"
      identifiers = formatlist("arn:${data.aws_partition.current.partition}:iam::%s:root", var.ci_cd_account_ids)
    }

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

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/Service"
      values   = [var.deployomat_service_name]
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

  statement {
    actions = [
      "sts:TagSession"
    ]

    principals {
      type        = "AWS"
      identifiers = formatlist("arn:${data.aws_partition.current.partition}:iam::%s:root", var.ci_cd_account_ids)
    }

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

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/Service"
      values   = [var.deployomat_service_name]
    }
  }
}

# Allow reading config/* and roles/var.deployomat_service_name for any account
# in the source principal's environment, _or_ for _any_ account if the source principal's
# environment is production.
data "aws_iam_policy_document" "allow-ssm-read" {
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.id}:parameter/omat/account_registry/*",
      "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.id}:parameter/${var.organization_prefix}/&{aws:PrincipalTag/Environment}/*/config/*",
      "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.id}:parameter/${var.organization_prefix}/&{aws:PrincipalTag/Environment}/*/roles/${var.deployomat_service_name}",
    ]
  }

  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.id}:parameter/${var.organization_prefix}/*/*/config/*",
      "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.id}:parameter/${var.organization_prefix}/*/*/roles/${var.deployomat_service_name}"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/Environment"
      values   = ["production"]
    }
  }
}

resource "aws_iam_policy" "allow-ssm-read" {
  name   = "Allow${title(var.deployomat_service_name)}SSMParameterReads"
  policy = data.aws_iam_policy_document.allow-ssm-read.json

  description = "Allows reading config and roles/${var.deployomat_service_name} parameters using ABAC to scope environment access."

  tags = local.tags
}

resource "aws_iam_role" "role" {
  name               = "${title(var.deployomat_service_name)}ParameterAccess"
  assume_role_policy = data.aws_iam_policy_document.allow-deployomat-assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "allow-ssm-read" {
  role       = aws_iam_role.role.name
  policy_arn = aws_iam_policy.allow-ssm-read.arn
}
