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

Deploy messages come from deployomat's own deploy events (see "Deploy events" in the deployomat module README), so they name the AMI actually launched and, when the AMI has a `BuildCommit` tag that looks like a sha, the short commit. Pass `deploy_event = module.deployomat.deploy_event`; the default matches it. A deploy's Step Functions status events are only a backstop for what deployomat didn't report: a timeout, a console stop, a crash, or a finished event that didn't land. Deploy-source events that aren't a deploy notification are ignored. Cancel and undeploy messages still come from status events. Release this module with a deployomat that puts deploy events, or deploys lose their Started messages.

A run's ending (completed, failed, aborted, or unknown, for a result deployomat didn't recognise) always posts. `forward_phases` picks which other phases post, default `["started"]`. Add `"progress"` to post each step's line ("Shifted 40% of traffic to the new ASG"). A SkipNotifications deploy posts only failures, aborts and unknown endings.
