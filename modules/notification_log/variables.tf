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

variable "deploy_sfn" {
  type = object({
    arn  = string
    name = string
  })
  description = "The deployment step functions state machine."
}

variable "cancel_sfn" {
  type = object({
    arn  = string
    name = string
  })
  description = "The cancel step functions state machine."
  default     = null
}

variable "undeploy_sfn" {
  type = object({
    arn  = string
    name = string
  })
  description = "The undeploy step functions state machine."
}

variable "reader_account_ids" {
  type        = list(string)
  description = "IDs of AWS accounts to trust to assume the reader role. IAM policies inside those accounts should control who may."
}

variable "organization_prefix" {
  type        = string
  description = "The prefix on all SSM parameters and IAM role paths for this organization."
  default     = "teak"
}

variable "reader_role_name" {
  type        = string
  description = "The name of the role that can read the notification log group."
  default     = "DeployNotificationReader"
}

variable "external_id" {
  type        = string
  description = "The ExternalId to require when assuming the reader role, if necessary."
  default     = null
}

variable "log_retention_in_days" {
  type        = number
  description = "The number of days to keep notifications. Readers catch up from the log, so this is how long a reader can be away."
  default     = 90
}

variable "lambda_iam_role_arn" {
  type        = string
  description = "The ARN of an IAM role to assign to the created lambda. The required permissions are logging, and ec2:DescribeImages to add the AMI's commit to each notification (without it notifications have no commit). If null, this module will create a suitable IAM role and policy."
  default     = null
}

variable "lambda_name" {
  type        = string
  description = "The name of the lambda created by this module. The log group is /aws/lambda/<name>."
  default     = "DeployomatNotificationLog"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources. Will be deduplicated from default tags."
  default     = {}
}
