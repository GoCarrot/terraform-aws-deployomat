# Deployer Role

Terraform module which creates an IAM role to start and cancel Deployomat deploys.

## Usage

This is a complete example of a minimal deployomat setup.

```hcl
module "deployomat_meta_access" {
  source = "MODULE_PATH_GOES_HERE"

  # IDs of accounts where deployomat installations may run.
  ci_cd_account_ids = [data.aws_caller_identity.sandbox.id]

  # Defaults to "deployomat". I recommend keeping the default.
  deployomat_service_name = var.deployomat_service_name

  # This defaults to "teak". You may change it to a prefix for your own organization.
  # Deployomat expects all SSM parameters and IAM roles to be under paths starting with
  # /<organization_prefix>, and these modules will create IAM roles under such paths.
  organization_prefix = var.organization_prefix
}

module "deployomat_deploy_access" {
  source = "MODULE_PATH_GOES_HERE"

  # IDs of accounts where deployomat installations may run.
  ci_cd_account_ids = [data.aws_caller_identity.sandbox.id]

  # Defaults to "deployomat". I recommend keeping the default.
  deployomat_service_name = var.deployomat_service_name

  # This defaults to "teak". You may change it to a prefix for your own organization.
  # Deployomat expects all SSM parameters and IAM roles to be under paths starting with
  # /<organization_prefix>, and these modules will create IAM roles under such paths.
  organization_prefix = var.organization_prefix
}

# Deployomat requires a role arn published under "/<organization_prefix>/<environment>/<account_name>/roles/<deployomat_service_name>"
# in the same AWS account as the deployomat_meta_access module. It will read this role arn and
# assume it in order to perform deploy related operations.
resource "aws_ssm_parameter" "deployomat" {
  type  = "String"
  name  = "/${var.organization_prefix}/${var.environment}/${var.account_name}/roles/${var.deployomat_service_name}"
  value = module.deployomat_deploy_access.role.arn
}

module "deployomat" {
  source = "MODULE_PATH_GOES_HERE"

  deployomat_meta_role_arn = module.deployomat_meta_access.role.arn
  environment              = "development"

  # Defaults to "deployomat". I recommend keeping the default.
  deployomat_service_name = var.deployomat_service_name

  # This defaults to "teak". You may change it to a prefix for your own organization.
  # Deployomat expects all SSM parameters and IAM roles to be under paths starting with
  # /<organization_prefix>, and these modules will create IAM roles under such paths.
  organization_prefix = var.organization_prefix
}

module "deployer" {
  source = "MODULE_PATH_GOES_HERE"

  deploy_sfn_arn = module.deployomat.deploy_sfn.arn
  cancel_sfn_arn = module.deployomat.cancel_sfn.arn

  # The deployer role will be granted read access to all specified log groups.
  cloudwatch_log_group_arns = module.deployomat.cloudwatch_log_group_arns

  # IDs of accounts which should be allowed to perform deploys.
  # This module will trust the entire account, and IAM policies inside these
  # accounts should control who may assume the deployer role to perform deploys.
  user_account_ids = [data.aws_caller_identity.sandbox.id]

  # This defaults to "teak". You may change it to a prefix for your own organization.
  # Deployomat expects all SSM parameters and IAM roles to be under paths starting with
  # /<organization_prefix>, and these modules will create IAM roles under such paths.
  organization_prefix = var.organization_prefix
}

module "slack_notify" {
  source = "MODULE_PATH_GOES_HERE"

  # Must be a bot token that starts with xoxb.
  slack_bot_token            = var.slack_bot_token

  # The bot must be invited to this channel before notifications will work.
  slack_notification_channel = var.deployment_channel

  deploy_sfn                 = module.deployomat.deploy_sfn
}

```
