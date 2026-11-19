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

Deploy messages come from deployomat's own deploy events (see "Deploy events" in the deployomat module README), so they name the AMI actually launched and, when the AMI has a `BuildCommit` tag that looks like a sha, the short commit. Pass `deploy_event = module.deployomat.deploy_event`; the default matches it. A deploy's Step Functions status events are only a backstop for what deployomat didn't report: a timeout, a console stop, a crash, or a finished event that didn't land. Deploy-source events that aren't a deploy notification are ignored. Cancels and undeploys work the same way: deployomat's own events, with their Step Functions status events as the backstop. A cancel that a deploy or undeploy started (a concurrent-deploy cancel, a rollback) posts nothing; its parent reports. Release this module with a deployomat that puts these events, or deploys, cancels and undeploys lose their Started messages.
