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

variable "deploy_sfn_arn" {
  type        = string
  description = "ARN of the step function state machine for executing deploys."
}

variable "cancel_sfn_arn" {
  type        = string
  description = "ARN of the step function state machine for cancelling deploys."
}

variable "undeploy_sfn_arn" {
  type        = string
  description = "ARN of the step function state machine for undeploying services."
}

variable "user_account_ids" {
  type        = list(string)
  description = "AWS account id to delegate trust to for starting and stopping deploys."
}

variable "cloudwatch_log_group_arns" {
  type        = list(string)
  description = "The ARNs for cloudwatch log groups that the deployer should be able to read."
}

variable "organization_prefix" {
  type        = string
  description = "The prefix on all SSM parameters for this organization."
  default     = "teak"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources. Will be deduplicated from default tags."
  default     = {}
}

variable "role_name" {
  type        = string
  description = "The name of the role created for performing deploys."
  default     = "Deployer"
}

variable "external_id" {
  type        = string
  description = "The ExternalId to use when assuming roles, if necessary."
  default     = null
}
