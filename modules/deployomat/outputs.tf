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

output "deploy_sfn" {
  description = "The AWS Step Function created to manage deployments."
  value       = aws_sfn_state_machine.deploy
}

output "cancel_sfn" {
  description = "The AWS Step Function created to cancel deployments."
  value       = aws_sfn_state_machine.cancel-deploy
}

output "undeploy_sfn" {
  description = "The AWS Step Function created to undeploy services."
  value       = aws_sfn_state_machine.undeploy
}

output "cloudwatch_log_group_arns" {
  description = "The log group arns for all log groups the deployomat may log to."
  value       = concat(values(aws_cloudwatch_log_group.lambda)[*].arn, [aws_cloudwatch_log_group.sfn.arn])
}
