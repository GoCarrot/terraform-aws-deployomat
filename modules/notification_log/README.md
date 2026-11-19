# Notification Log

Terraform module which writes a Teak deploy notification to a CloudWatch log group for each deploy, cancel and undeploy transition, and creates a read-only role for whatever reads them.

It follows `slack_notifier`: the same EventBridge rule and a Lambda, which writes one JSON line (`teak.deploy.notification/1`) to its own log group instead of posting to Slack. Everything Step Functions-specific stays in `src/notification_event.rb`, so a reader only knows the notification.

The rule also matches deployomat's own events (`deploy_event`, defaulting to the deployomat module's output), which are logged as they arrive; see [Deploy events](../deployomat/README.md#deploy-events). A run that ends `SUCCEEDED` with output status `fail` is logged as `failed`.

## Usage

```hcl
# Where the AWS provider is for an AWS account which contains the Deployomat.
module "notification_log" {
  source = "GoCarrot/deployomat/aws//modules/notification_log"

  deploy_sfn   = module.deployomat.deploy_sfn
  undeploy_sfn = module.deployomat.undeploy_sfn
  cancel_sfn   = module.deployomat.cancel_sfn
  deploy_event = module.deployomat.deploy_event

  # Accounts trusted to assume the reader role.
  reader_account_ids = [data.aws_caller_identity.admin.id]
}
```

## Plan and apply in separate runs

The Lambda zip is built by `archive_file` during plan, at `<module path>/build/notification_log.zip`. A saved plan doesn't build it again at apply. If your pipeline saves the plan and applies it in a later job (deployinator's CircleCI does), carry that file across too, the same way you carry `deployomat`'s `lambda.zip` and `slack_notifier`'s `slack_notify.zip`, or the apply can't find it.

## Reading

Assume `module.notification_log.reader_role` and read the log group:

```sh
aws logs filter-log-events --log-group-name /aws/lambda/DeployomatNotificationLog \
  --filter-pattern '"teak.deploy.notification/1"' --start-time <epoch ms>
```

The log group also holds the Lambda's own START/END/REPORT lines, hence the filter. `log_retention_in_days` (default 90) is how long a reader can be away and still catch up.

## Notification

```json
{"schema":"teak.deploy.notification/1","event_id":"...","time":"2026-11-16T22:00:00Z",
 "kind":"deploy","phase":"started","service":"carrot","account":"production",
 "ami":"ami-0abc","execution":"...","execution_arn":"...","errors":[],"skip_notifications":false,
 "ami_tags":{"BuildCommit":"09c4f525..."}}
```

Deployomat's own events add `ami_tags` (every tag on the AMI, `{}` if none could be read) and, when a deploy was started with a `$` command, `ami_requested`; `ami` is then the AMI actually launched. Cancels and undeploys have no AMI: `ami` is null. `event_id` is `<execution>/<phase>`, the same on a retried put, and `<execution>/progress/<hash of progress>` for `progress`.

`kind` is `deploy`, `cancel` or `undeploy`. `phase` is `started`, `progress`, `completed`, `failed`, `aborted` or `unknown`. `skip_notifications` mirrors `DeployConfig.SkipNotifications`; it is passed through, not acted on.
