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
