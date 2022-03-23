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

variable "slack_bot_token" {
  type        = string
  description = "A slack bot token for an app."
  sensitive   = true
}

variable "slack_notification_channel" {
  type        = string
  description = "The channel to notify on deployment events."
}

variable "create_log_group" {
  type        = bool
  description = "Set to true to have this module manage a log group for the Lambda function."
  default     = true
}

variable "log_retention_in_days" {
  type        = number
  description = "The number of days to retain Lambda logs for."
  default     = 90
}

variable "deploy_sfn" {
  type = object({
    arn  = string
    name = string
  })
  description = "The deployment step functions state machine."
}

variable "undeploy_sfn" {
  type = object({
    arn  = string
    name = string
  })
  description = "The undeploy step functions state machine."
}

variable "lambda_iam_role_arn" {
  type        = string
  description = "The ARN of an IAM role to assign to the created lambda. The only required permissions are for logging. If null, this module will create a suitable IAM role and policy."
  default     = null
}

variable "lambda_name" {
  type        = string
  description = "The name of the lambda created by this module."
  default     = "DeployomatSlackNotify"
}

variable "source_file" {
  type        = string
  description = "Path to an alternate handler. Must be implemented in Ruby 2.7, be named slack_notify.rb, and have a SlackNotify.handler method."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources. Will be deduplicated from default tags."
  default     = {}
}

variable "techno" {
  type        = bool
  description = "Play some hot techno beats on undeployment."
  default     = false
}

variable "hot_techno_beats" {
  type        = string
  description = "A link to the hot techno beats to play on undeployment."
  default     = "https://www.youtube.com/watch?v=Z1TlbLfaJp8"
}
