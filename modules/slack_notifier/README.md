# Slack Notifier

Terraform module which creates a Lambda (and optionally associated log group and IAM role) for posting notifications of Deployomat deployment status to Slack.

## Usage

```hcl
# Where the AWS provider is for an AWS account which contains the Deployomat.
module "slack_notifier" {
  source = "MODULE_PATH_GOES_HERE"

  slack_bot_token            = "xoxb-xxxx"
  slack_notification_channel = "deploy-status"
}
```
