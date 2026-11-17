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

output "log_group" {
  description = "The log group the notifications are written to."
  value       = aws_cloudwatch_log_group.lambda
}

output "reader_role" {
  description = "The IAM role that can read the log group. Assume it, then `aws logs filter-log-events`."
  value       = aws_iam_role.reader
}

output "notification_lambda" {
  description = "The lambda that turns execution status changes into notifications."
  value       = aws_lambda_function.notification-log
}
