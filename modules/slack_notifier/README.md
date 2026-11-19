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

## Deploy messages

Messages come from deployomat's own events (see [Deploy events](https://github.com/GoCarrot/terraform-aws-deployomat/blob/main/modules/deployomat/README.md#deploy-events)). Pass `deploy_event = module.deployomat.deploy_event`; the default matches it. They name the AMI actually launched and, when it has a `BuildCommit` tag that looks like a sha, the short commit.

A run's ending always posts. `forward_phases` picks which other phases post, default `["started"]`; add `"progress"` for each step's line. A SkipNotifications deploy posts only failures, aborts and unknown endings.
