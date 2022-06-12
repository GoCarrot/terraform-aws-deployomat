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

variable "organization_prefix" {
  type        = string
  description = "The prefix on all SSM parameters for this organization."
  default     = "teak"
}

variable "deployomat_service_name" {
  type        = string
  description = "The value of the Service tag on all deployomat related resources (including roles!)"
  default     = "deployomat"
}

variable "ci_cd_account_ids" {
  type        = list(string)
  description = "The set of account ids for CI/CD accounts in the organization that should be allowed to deploy to the current account."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources. Will be merged with Service=var.deployomat_service_name and deduplicated from default tags."
  default     = {}
}

variable "external_id" {
  type        = string
  description = "The ExternalId to use when assuming roles, if necessary."
  default     = null
}
