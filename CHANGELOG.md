## 0.3.7

ENHANCEMENTS:

* Add elasticloadbalancing:AddTags IAM permission to deploy_access_role to comply with upcoming AWS security changes.

## 0.3.6

BUG FIXES:

* Actually retry ASG creation.

## 0.3.5

BUG FIXES:

* Fix exception when retrying ASG creation.

## 0.3.4

ENHANCEMENTS:

* Now supports AutoScaling Group metrics.

## 0.3.3

ENHANCEMENTS:

* Retry creating AutoScaling Group.

## 0.3.2

ENHANCEMENTS:

* Permit longer names for automatic undeployment rules to minimize conflicts.

## 0.3.1

BUG FIXES:

* Cancelling a deploy of a web service during its Bake period now correctly rolls back to the previous production deploy.

## 0.3.0

ENHANCEMENTS:

* Deploy, undeploy, and cancel now support services which have multiple load balancer rules directing traffic to them.

## 0.2.22

ENHANCEMENTS:

* Target group attributes (deregistration delay, stickiness, load balancing algorithm) are now supported.

## 0.2.21

BUG FIXES:

* Syntax error.

## 0.2.20

BUG FIXES:

* Limit length of target group name, but better.

## 0.2.19

BUG FIXES:

* Limit length of ASG/target group names to avoid naming conflicts.

## 0.2.18

BUG FIXES:

* Limit length of automatic undeploy rule name, but better.

## 0.2.17

BUG FIXES:

* Limit length of automatic undeploy rule name.

## 0.2.16

BUG FIXES:

* Fixed language for starting undeployment slack notification.
* Support external id when assuming roles ([#2](https://github.com/GoCarrot/terraform-aws-deployomat/pull/2))

SPECIAL THANKS:

* [@MrJoy](https://github.com/MrJoy)

## 0.2.15

ENHANCEMENTS:

* Slack notifier now supports custom update events.
* Slack notifier now optionally supports notifying on deploy cancels by setting the cancel_sfn input.

## 0.2.14

ENHANCEMENTS:

* Support multiple deployer roles.

## 0.2.13

ENHANCEMENTS:

* Updated IAM policies to allow Deployomat to read service logs for the service being deployed. This will be used by the Zookeeper Deployomat.

## 0.2.12

BUG FIXES:

* Resolve circular dependency introduced by 0.2.11 by splitting lambda related permissions into a separate policy.

## 0.2.11

BUG FIXES:

* Ensure that DeployomatStates IAM policy for DeployomatStates role is attached before attempting to create state machines with DeployomatStates states role.

## 0.2.10

ENHANCEMENTS:

* Now supports launch templates with tag specifications.

## 0.2.9

ENHANCEMENTS:

* Now supports JSON encoded lb_listener_arns parameters.

## 0.2.8

BUG FIXES:

* Fix exception updating default launch template version.

## 0.2.7

ENHANCEMENTS:

* Set the most recently deployed launch template version as the default launch template version.

## 0.2.6

ENHANCEMENTS:

* Nicely error on ASG clone failure and destroy target group if applicable.

## 0.2.5

ENHANCEMENTS:

* Add support for autoscaling groups with placement group configuration.

## 0.2.4

ENHANCEMENTS:

* Add support for "command" AMI Ids on deployment. Available commands are $name-prefix:{ami_name}, which will deploy the most recently created AMI prefixed with the given {ami_name}, and $launchtemplate:({version}|$Latest|$Default|$LatestMinus:{count}), which will either deploy the given launch template version, the $Latest launch template version, the $Default launch template version, or the $Latest launch template version minus {count}.

## 0.2.3

BUG FIXES:

* Ensure target group names are valid.

## 0.2.2

BUG FIXES:

* Fix deployment failure when there is no existing automatic undeploy. ABAC is hard y'all

## 0.2.1

BUG FIXES:

* Fix error when provisioning deploy_access_role if Service is not a default tag on the provider or var.tags includes a tag that is not a default tag on the provider.
* Fix error when provisioning meta_access_role if Service is not a default tag on the provider or var.tags includes a tag that is not a default tag on the provider.
* Fix error when provisioning deployer_role if var.tags includes a tag that is not a default tag on the provider.
* Fix error when provisioning slack_notifier if var.tags includes a tag that is not a default tag on the provider.
* Fix error when provisioning deployomat if Service or Environment is not a default tag on the provider or var.tags includes a tag that is not a default tag on the provider.
* Fix deployment failure when there is no existing automatic undeploy.

## 0.2.0

BREAKING CHANGES:

* deployer_role now requires an undeploy_sfn_arn input.
* slack_notifier now requires an undeploy_sfn input.

ENHANCEMENTS:

* Undeploy. Invoking the Undeploy state machine with a service name and account name will destroy _production_ assets of that service in the given account. Because this is potentially dangerous, undeploy requires a service deployment to opt in to undeployment by setting DeployConfig.AllowUndeploy to true on deployment, or by being deployed into an account whose environment is not "production". If DeployConfig.AllowUndeploy is explicitly set to false, services deployed in an account whose environment is not "production" also cannot be undeployed.
* Automatic Undeployment. Any service that can be undeployed can be deployed with DeployConfig.AutomaticUndeployMinutes set. Deployomat will automatically undeploy the service the specified number of minutes after a successful deploy with such a configuration.
* Nicely error out on deploy if the template ASG cannot be identified.
* Provide known errors to the Slack Notifer, which it now provides when a deployment fails for a known resason.

## 0.1.2

BUG FIXES:

* Fixed Config retrieving organization prefix from account prefix.

## 0.1.1

BUG FIXES:

* Fixed typo in Config#deploy_role_arn

## 0.1.0

BREAKING CHANGES:

* AccountName is no longer a valid input. Instead, you must provide AccountCanonicalSlug, which must be the canonical slug for an account managed by [Accountomat](https://github.com/GoCarrot/terraform-aws-accountomat).

ENHANCEMENTS:

* If SkipNotifications is true, still notify for failed deployments.

## 0.0.8

BUG FIXES:

* When cancelling a deploy, if listener_arns are configured but no rules are found, complete the cancel.

ENHANCEMENTS:

* If the deployment configuration includes a truthy SkipNotifications input, slack notifier will not ping slack.

## 0.0.7

BUG FIXES:

* If the production auto scaling group is temporarily above its max instance count, clamp instance count for preventing scale in to the configured max instance count.

## 0.0.6

BUG FIXES:

* Don't have syntax errors.

## 0.0.5

ENHANCEMENTS:

* Support AWS Provider 4.x.

## 0.0.4

BUG FIXES:

* If the production auto scaling group is temporarily above its max instance count, clamp instance count for the new auto scaling group to the configured max instance count.

## 0.0.3

ENHANCEMENTS:

* Support "rollback" of an intial deployment. This will reset to as clean a state as possible.

KNOWN ISSUES:

* If deployment of a web service encounters an error when cloning the template autoscaling group the cloned target groups will not be deleted by the rollback.

## 0.0.2

ENHANCEMENTS:

* Make deployer role name configurable.
* Allow zero sized auto scaling groups.

## 0.0.1

Initial release
