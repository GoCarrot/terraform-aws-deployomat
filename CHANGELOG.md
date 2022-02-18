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
