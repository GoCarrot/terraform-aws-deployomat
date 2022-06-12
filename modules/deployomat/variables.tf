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

variable "deployomat_meta_role_arn" {
  description = "The role ARN for a role provisioned by the meta_access_role module. Deployomat will assume this role to read configuration details."
  type        = string
}

variable "deployomat_service_name" {
  type        = string
  description = "The value of the Service tag on all deployomat related resources (including roles!)"
  default     = "deployomat"
}

variable "log_retention_in_days" {
  type        = number
  description = "The number of days to retain Lambda logs for."
  default     = 90
}

variable "organization_prefix" {
  type        = string
  description = "The prefix on all SSM parameters for this organization."
  default     = "teak"
}

variable "environment" {
  description = "The SDLC environment that this deployomat instance is responsible for, e.g. development. This is used for ABAC for assuming roles provisioned by the deploy_access_role module."
  type        = string
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources. Will be merged with Service=var.deployomat_service_name and Environment=var.environment, and deduplicated from default tags."
  default     = {}
}

variable "ami_owner_account_ids" {
  type = list(string)
  description = <<-EOT
  A list of AWS account ids which can create AMIs that Deployomat's AMI lookup should consider.
  This is a security feature so Deployomat will not deploy an AMI that a malicious actor may have shared to
  your account. If null, this will default to the account id that this Deployomat is being deployed in. If set
  to an empty list, will disable AMI lookup.
EOT
  default = null
}

variable "external_id" {
  type        = string
  description = "The ExternalId to use when assuming roles, if necessary."
  default     = null
}
