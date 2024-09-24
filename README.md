# Deployomat

Deployomat is a tool to manage AMI deployments on AWS. It functions by updating an [EC2 Launch Template](https://docs.aws.amazon.com/autoscaling/ec2/userguide/LaunchTemplates.html) and then cloning a template [EC2 AutoScaling Group](https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html) and all associated resources. If the template AutoScaling Group is associated with a [Target Group](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html) which is associated with an exemplar [Application Load Balancer Rule](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/listener-update-rules.html) then Deployomat will perform a gradual blue/green deployment, otherwise Deployomat will simply allow the new deployment and previous deployment to run concurrently for a defined bake time before terminating the previous deployment.

## Features

### Blue/Green Deployment of Web Services

## Installation

This is a complete example of a minimal deployomat setup.

```hcl
data "aws_caller_identity" "current" {}

module "deployomat_meta_access" {
  source = "GoCarrot/deployomat/aws//modules/meta_access_role"

  # IDs of accounts where deployomat installations may run.
  ci_cd_account_ids = [data.aws_caller_identity.current.id]

  # Defaults to "deployomat". I recommend keeping the default.
  deployomat_service_name = var.deployomat_service_name

  # This defaults to "teak". You may change it to a prefix for your own organization.
  # Deployomat expects all SSM parameters and IAM roles to be under paths starting with
  # /<organization_prefix>, and these modules will create IAM roles under such paths.
  organization_prefix = var.organization_prefix
}

module "deployomat_deploy_access" {
  source = "GoCarrot/deployomat/aws//modules/deploy_access_role"

  # IDs of accounts where deployomat installations may run.
  ci_cd_account_ids = [data.aws_caller_identity.current.id]

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
  source = "GoCarrot/deployomat/aws//modules/deployomat"

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
  source = "GoCarrot/deployomat/aws//modules/deployer_role"

  deploy_sfn_arn   = module.deployomat.deploy_sfn.arn
  cancel_sfn_arn   = module.deployomat.cancel_sfn.arn
  undeploy_sfn_arn = module.deployomat.undeploy_sfn.arn

  # The deployer role will be granted read access to all specified log groups.
  cloudwatch_log_group_arns = module.deployomat.cloudwatch_log_group_arns

  # IDs of accounts which should be allowed to perform deploys.
  # This module will trust the entire account, and IAM policies inside these
  # accounts should control who may assume the deployer role to perform deploys.
  user_account_ids = [data.aws_caller_identity.current.id]

  # This defaults to "teak". You may change it to a prefix for your own organization.
  # Deployomat expects all SSM parameters and IAM roles to be under paths starting with
  # /<organization_prefix>, and these modules will create IAM roles under such paths.
  organization_prefix = var.organization_prefix
}

module "slack_notify" {
  source = "GoCarrot/deployomat/aws//modules/slack_notifier"

  # Must be a bot token that starts with xoxb.
  slack_bot_token            = var.slack_bot_token

  # The bot must be invited to this channel before notifications will work.
  slack_notification_channel = var.deployment_channel

  deploy_sfn                 = module.deployomat.deploy_sfn
  undeploy_sfn               = module.deployomat.undeploy_sfn
}

# These SSM parameters are optional but extremely useful for being able to integrate Deployomat
# into a CI/CD workflow.
#
# Presuming your CI/CD workflow has AWS credentials which allow it to read SSM parameters and
# assume the deployer role, you can use the following CLI commands and these parameters to
# initiate a deploy.
#
# #!/bin/sh
# PREFIX="/${ORGANIZATION_PREFIX}/${CICD_ENVIRONMENT}/${CICD_ACCOUNT_NAME}"
# ROLE_ARN=$(aws ssm get-parameter --name "${PREFIX}/roles/deployer" --query Parameter.Value --output text)
# DEPLOY_SFN=$(aws ssm get-parameter --name "${PREFIX}/config/${DEPLOYOMAT_SERVICE_NAME}/deploy_sfn" --query Parameter.Value --output text)
# INPUT=$(jq --null-input '{"AccountCanonicalSlug": $ENV.DEPLOY_ACCOUNT, "ServiceName": $ENV.DEPLOY_SERVICE, "AmiId": $ENV.DEPLOY_AMI}')
# # Override our current AWS credentials with temporary credentials for the deploye role
# eval $(aws sts assume-role --role-arn ${ROLE_ARN} --role-session-name "deploy_${DEPLOY_SERVICE}" |\
#        jq -r '.Credentials | "export AWS_ACCESS_KEY_ID=\(.AccessKeyId)\nexport AWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)\nexport AWS_SESSION_TOKEN=\(.SessionToken)\n"')
# # Start the deploy.
# aws stepfunctions start-execution --state-machine-arn ${DEPLOY_SFN} --input ${INPUT}
resource "aws_ssm_parameter" "deployer_role" {
  type  = "String"
  name  = "/${var.organization_prefix}/${var.environment}/${var.account_name}/roles/deployer"
  value = module.deployer.role.arn
}

resource "aws_ssm_parameter" "deploy_sfn_arn" {
  type  = "String"
  name  = "/${var.organization_prefix}/${var.environment}/${var.account_name}/config/${var.deployomat_service_name}/deploy_sfn_arn"
  value = module.deployomat.deploy_sfn.arn
}

resource "aws_ssm_parameter" "cancel_sfn_arn" {
  type  = "String"
  name  = "/${var.organization_prefix}/${var.environment}/${var.account_name}/config/${var.deployomat_service_name}/cancel_sfn_arn"
  value = module.deployomat.cancel_sfn.arn
}

resource "aws_ssm_parameter" "undeploy_sfn_arn" {
  type  = "String"
  name  = "/${var.organization_prefix}/${var.environment}/${var.account_name}/config/${var.deployomat_service_name}/undeploy_sfn_arn"
  value = module.deployomat.undeploy_sfn.arn
}
```

While all resources can be provisioned into a single account, Deployomat is intended to be used in a multi-account organization containing at a minimum the following account types:
- Workload account, which contains production user facing services. The deployomat_deploy_access module should be provisioned in every workload account which Deployomat can deploy to.
- CI/CD account, which contains CI/CD related tooling. The deployomat, deployer_role, and slack_notify modules should be provisioned in every CI/CD account.
- Meta/Config account, which contains SSM parameters for all accounts. Deployomat looks for the following SSM parameters
  - /omat/account_registry/${AccountCanonicalSlug}, which should be configured by [Accountomat](https://registry.terraform.io/modules/GoCarrot/accountomat/aws/latest)
  - /${organization_prefix}/${environment}/${account_name}/roles/${deployomat_service_name}, which should contain the role arn for deployomat to assume to manage deploys in account_name
  - /${organization_prefix}/${environment}/${account_name}/config/${service_name}/listener_arns, which should be a StringList type parameter containing all Application Load Balancer listener arns that the service is expected to be available under. If this parameter is absent Deployomat will assume that the service is not a web facing service and will not perform a gradual rollout.
- User account, which contains IAM users and roles representing people or services who can execute deploys.

## How To Use

### Account Management

Deploymat requires the use of [Accountomat](https://registry.terraform.io/modules/GoCarrot/accountomat/aws/latest) or [Accountomat/parameters](https://registry.terraform.io/modules/GoCarrot/accountomat/aws/latest/submodules/parameters) to define available accounts. All Deployomat operations take `AccountCanonicalSlug` as an input, which must be the `canonical_slug` output of an Accountomat or Accountomat/parameters module declared in the same account as Deployomat/meta_access_role.

### Service Setup

At its core, Deployomat functions by updating an existing EC2 Launch Template and then cloning an existing EC2 AutoScaling Group, updating it to use the newly created launch template version. The existing EC2 AutoScaling Group must already be configured to use the EC2 Launch Template.

Check out [Serviceomat](https://registry.terraform.io/modules/GoCarrot/serviceomat/aws/latest) for a module which creates AWS resources for Deployomat to deploy.

A minimum viable service setup could be

```hcl
variable "instance_type" {
  description = "The EC2 instance type this service should be deployed to".
  type        = string
}

variable "min_instances" {
  description = "The minimum number of instances this service should run on"
  type        = number
}

variable "max_instances" {
  description = "The maximum number of instances this service should run on"
  type        = number
}

variable "security_group_ids" {
  description = "List of security groups to attach to service instances."
  type        = list(string)
  default     = []
}

variable "subnet_ids" {
  description = "List of VPC subnets this service should run in."
  type        = list(string)
}

# Get an AMI that will run on the selected instance type so that launch template creation succeeds.
data "aws_ec2_instance_type" "instance-info" {
  instance_type = var.instance_type
}

locals {
  instance_arch       = data.aws_ec2_instance_type.instance-info.supported_architectures[0]
  debian_arch_mapping = { arm64 = "arm64", x86_64 = "amd64" }
}

data "aws_ssm_parameter" "stub-ami" {
  name = "/aws/service/debian/release/11/latest/${local.debian_arch_mapping[local.instance_arch]}"
}

resource "aws_launch_template" "template" {
  name_prefix = "example-lt"

  image_id = data.aws_ssm_parameter.stub-ami.value

  instance_type = var.instance_type
  ebs_optimized = true

  vpc_security_group_ids = var.security_group_ids

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 10
      delete_on_termination = true
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
    }
  }

  # You should use IMDSv2.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # VERY IMPORTANT.
  # We must ignore image_id and latest_version changes so that new versions created by Deployomat
  # do not cause state modifications in Terraform. You may make modifications in terraform and apply
  # them, and all subsequent Deployomat managed deploys will use those modifications.
  #
  # In other words, anything you can configure in this launch template can be deployed with Deployomat.
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [image_id, latest_version]
  }
}

resource "aws_autoscaling_group" "asg" {
  name     = "example-template"
  min_size = 0
  max_size = 0

  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.template.id
    version = "$Default"
  }

  lifecycle {
    create_before_destroy = true
  }

  # Deployomat uses these special tags to configure the min_size and max_size of cloned ASGs. This
  # allows the example ASG to be empty and therefore not require spending any money.
  tags = [
    {
      key                 = "${var.organization_prefix}:min_size"
      value               = var.min_instances
      propagate_at_launch = false
    },
    {
      key                 = "${var.organization_prefix}:max_size"
      value               = var.max_instances
      propagate_at_launch = false
    }
  ]
}
```

For a web service behind an Application Load Balancer, Deployomat additionally requires
- An existing rule on all listeners with its priority offset by 40,000 from the desired rule priority. Deployomat will clone this rule and subtract 40,000 from its priority as part of the initial deploy. Deployomat will _NOT_ copy any modifications made to the rule after the initial deploy.
- A target group associated with the template ASG
- A list of Application Load Balancer listener arns published under `/${organization_prefix}/${environment}/${account_name}/config/${service_name}/listener_arns` in the account containing the meta_access_role module.

You could make the following additions and changes to the prior example for a web service

```hcl
variable "vpc_id" {
  description = "The ID of the VPC which this service is deployed in. The Application Load Balancer must also be contained in this VPC."
  type        = string
}

variable "port" {
  description = "The port number that the service is accessible under."
  type        = number
  default     = 80
}

variable "listener_arns" {
  description = "The ARNs of all Application Load Balancer listeners (e.g. the HTTP and HTTPS listeners) this service should be deployed to."
  type        = list(string)
}

variable "host" {
  description = "The FQDN of this service, e.g. service.example.com"
  type        = string
}

resource "aws_lb_target_group" "example-template" {
  port     = var.port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 5
    timeout             = 4
    matcher             = "200-299"
    path                = "/"
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "example-route-template" {
  for_each = toset(var.listener_arns)

  listener_arn = each.value
  priority     = var.lb_priority + 40000

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.example-template.arn
  }

  condition {
    host_header {
      values = [var.host]
    }
  }
}

resource "aws_autoscaling_group" "asg" {
  ...
  target_group_arns = [aws_lb_target_group.example-template.arn]
}
```

Note that Deployomat currently only supports a single target group per service.

Deployomat supports and will clone autoscaling policies. To automatically scale the service based on CPU utilization for example, you could add

```hcl
variable "target_cpu" {
  description = "The CPU utilization that the autoscaling group should scale up/down to maintain."
  type        = number
  default = 50
}

resource "aws_autoscaling_policy" "avg-cpu" {
  name                   = "target-cpu"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.target_cpu
  }
}
```

#### Service Roles

If the deployed EC2 instances have an IAM role associated with them, the IAM role _must_ have a path prefixed with `/${var.organization_prefix}/service-role`. Deployomat takes privilege escalation seriously and may only perform iam:PassRole operations for roles containing that prefix. This prevents Deployomat from being used to grant EC2 instances arbitrary roles, e.g. OrganizationAccountAccessRole.

### Running Deploys

Deployomat is intended to be used by assuming the role configured by the deployer_role module and then starting the deploy_sfn AWS Step Functions state machine. The minimal input is a JSON document containing AccountCanonicalSlug, ServiceName, and AmiId keys. For example, using the aws cli, `aws stepfunctions start-execution --state-machine-arn <DEPLOY_SFN_ARN> --input '{"AccountCanonicalSlug":"workload-dev-0001", "ServiceName":"example", "AmiId": "ami-xxxx"}'`

Additional deploy options may be configured under a `DeployConfig` in the input. The following parameters are supported
- `DeployConfig.BakeTime` controls how long Deployomat will pause after a deploy is complete before tearing down the previous deploy in seconds. The default is 60.
- `DeployConfig.TrafficShiftPerStep` controls the percentage of traffic away from the previous deployment to the new deployment during rollout of web services. The default is 5.
- `DeployConfig.WaitPerStep` controls how long Deployomat will wait between each traffic shift during rollout of web services in seconds. The default is 15.
- `DeployConfig.HealthTimeout` controls how long Deployomat will wait in seconds for all instances in the new AutoScaling Group to become healthy before proceeding with the deploy. If all instances do not become healthy within the timeout Deployomat will abort the deploy. Default is 300.
- `DeployConfig.OnConcurrentDeploy` controls how Deployomat will behave if a deploy of a service in an account is started while another deploy of the same service in the same account is active. Valid values are
  - `fail` Deployomat will abort the current deploy if another is active
  - `rollback` This is the default. Deployomat will first initiate a rollback of the current deploy before proceeding with the newly requested deploy.
- `DeployConfig.AllowUndeploy` controls if the deployed service may be undeployed. If left unspecified, this will default to true unless the environment configured for the account is "production".
- `DeployConfig.AutomaticUndeployMinutes` enables automatic undeployment of the service. Once the given number of minutes elapses after a successful deployment Deployomat will automatically undeploy the service. It is an error to provide this configuration if the service cannot be undeployed.

### Cancelling Deploys

A deploy may be cancelled by starting an execution of `cancel_sfn.arn`. The input is a JSON document containning AccountCanonicalSlug and ServiceName keys. For example, using the aws cli, `aws stepfunctions start-execution --state-machine-arn <CANCEL_SFN_ARN> --input '{"AccountCanonicalSlug":"workload-dev-0001", "ServiceName": "example"}'` A cancelled deploy will immediately direct all traffic to the previously deployed version of the service and tear down the in-progress deploy.

### Undeploying

Undeploying is the act of tearing down/decommissioning all running servers and related configuration for a running service. After undeploying a service, there will be nothing pertaining to the service still managed by Deployomat. To completely remove a service, destroy the relevant serviceomat module after undeploying with Deployomat.

Deployomat operates with a "lift the safety then press the button" approach to undeployments. Before a service can be undeployed, it must first be deployed with `DeployConfig.AllowUndeploy` set to true. Note that if the account the service is deployed in has an environment other than "production" then `DeployConfig.AllowUndeploy` will default to true for all deployments, so a service can be directly undeployed. If the service is in an account with an environment set to "production", or if `DeployConfig.AllowUndeploy` has been explicitly set to false, then the safety is engaged and a deploy with `DeployConfig.AllowUndeploy` set to true must be done first.

Once the safety is lifted, a service may be undeployed by starting an execution of `undeploy_sfn.arn`. The input is a JSON document containning AccountCanonicalSlug and ServiceName keys. For example, using the aws cli, `aws stepfunctions start-execution --state-machine-arn <UNDEPLOY_SFN_ARN> --input '{"AccountCanonicalSlug":"workload-dev-0001", "ServiceName": "example"}'`.
