# Deploy Access Role

Terraform module which creates an IAM role for Deployomat to manage deployments.

## Assumptions

### Attribute Based Access Control

This module assumes that the Deployomat role will have Environment and Service tags. It is expected that the Environment tag reflect part of the software development lifecycle (e.g., `development` or `production`), and that the Service tag be equal to `var.deployomat_service_name`. This tag structure is used for [attribute based access control](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html) to SSM parameters.

This module will _not_ assign any tags for you. It assumes that an Environment tag will be specified as a [default tag](https://www.hashicorp.com/blog/default-tags-in-the-terraform-aws-provider) in your AWS provider configuration.

The Deployomat service will only be able to assume Deployer roles which correspond to the service's environment. That is, a development Deployomat service will only be able to assume development Deployer roles, and a production Deployomat service will only be able to assume production Deployer roles.

### Service IAM roles

If the service being deployed has an associated IAM role, its path must be `/${var.organization_prefix}/service-role/`. This is the only way to limit the IAM roles that the Deployomat may pass to other AWS services in order to avoid unintended privilege escalation.

## Usage

```hcl
# Where the AWS provider is for an AWS account which handles workloads of services to be deployed.
module "deploy_access_role" {
  source = "MODULE_PATH_GOES_HERE"

  organization_prefix = "short_version_of_your_org_name"
  ci_cd_account_ids   = [list_of, aws_account_ids, deploymat_runs_in]
}
```

A more fleshed out example showing how to create CI/CD accounts

```hcl
locals {
  admin_email         = "admin@example.com"
  admin_email_parts   = split("@", local.admin_email)
  admin_email_prefix  = local.admin_email_parts[0]
  admin_email_domain  = local.admin_email_parts[1]
  organization_prefix = "example"
}

resource "aws_organizations_organization" "org" {
  feature_set = "ALL"

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com"
  ]
}

# Organizational unit that all CI/CD accounts should be under.
resource "aws_organizations_organizational_unit" "ci_cd" {
  name      = "CI/CD"
  parent_id = aws_organizations_organization.org.roots[0].id
}

# Holder account for development/sandbox CI/CD development
resource "aws_organizations_account" "ci_cd_dev" {
  name      = "Dev - CI/CD"
  email     = "${admin_email_prefix}+aws_ci_cd_dev@${admin_email_domain}"
  parent_id = aws_organizations_organizational_unit.ci_cd.id

  role_name = "OrganizationAccountAccessRole"

  tags = {
    Environment = "development"
  }
}

# Account for production CI/CD
resource "aws_organizations_account" "ci_cd_prod" {
  name      = "Prod - CI/CD"
  email     = "${admin_email_prefix}+aws_ci_cd_prod@${admin_email_domain}"
  parent_id = aws_organizations_organizational_unit.ci_cd.id

  role_name = "OrganizationAccountAccessRole"

  tags = {
    Environment = "production"
  }
}

module "deploy_access_role" {
  source = "GoCarrot/deployomat/aws//modules/deploy_access_role"

  organization_prefix = local.organization_prefix

  ci_cd_account_ids = [
    aws_organizations_account.ci_cd_dev.id,
    aws_organizations_account.ci_cd_prod.id
  ]
}
```
