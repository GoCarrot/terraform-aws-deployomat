# Slack Notifier

Terraform module which creates a Lambda (and optionally associated log group and IAM role) for posting notifications of Deployomat deployment status to Slack.

## Usage

```hcl
# Where the AWS provider is for an AWS account which contains the Deployomat.
module "slack_notifier" {
  source = "GoCarrot/deployomat/aws//modules/slack_notifier"

  slack_bot_token            = "xoxb-xxxx"
  slack_notification_channel = "deploy-status"
}
```
