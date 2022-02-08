# Meta Access Role

Terraform module which creates an IAM role for Deployomat to access SSM parameters.

## Assumptions

### Parameter Structure

This module assumes that the AWS account storing parameters uses the Teak standard parameter naming scheme (which is totally a real thing that will definitely have documentation some day). The short version is:

Parameters are prefixed with `/${var.organization_prefix}/${var.sdlc_environment}/${var.account_name}`. Within this prefix are the special paths `/roles`, which stores all [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) associated with the account, and `/config/${var.service_name}`, where each service may store configuration details.

Configuration parameters _should not_ be used for sensitive data.

### Attribute Based Access Control

This module assumes that the Deployomat role will have Environment and Service tags. It is expected that the Environment tag reflect part of the software development lifecycle (e.g., `development` or `production`), and that the Service tag be equal to `var.deployomat_service_name`. This tag structure is used for [attribute based access control](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html) to SSM parameters.

This module will _not_ assign any tags for you. It assumes that an Environment tag will be specified as a [default tag](https://www.hashicorp.com/blog/default-tags-in-the-terraform-aws-provider) in your AWS provider configuration.

A Deployomat role which is tagged with Environment=development will only be able to access SSM parameters in the paths `/${var.organization_prefix}/development/*/config/*` and `/${var.organization_prefix}/development/roles/${var.deployomat_service_name}`. Similarily a Deployomat role which is tagged with Environment=test will only be able to access SSM parameters in the paths `/${var.organization_prefix}/test/*/config/*` and `/${var.organization_prefix}/test/roles/${var.deployomat_service_name}`.

The exception to this is any Deployomat role tagged with Environment=production which will be able to access SSM parameters in the paths `/${var.organization_prefix}/*/*/config/*` and `/${var.organization_prefix}/*/roles/${var.deployomat_service_name}`.

In short, a production Deployomat role may read parameters for _any_ environment, while Deployomat roles in other environments may only read parameters for _their_ environment.

## Usage

```hcl
# Where the AWS provider is for an AWS account which stores SSM parameters.
module "meta_access_role" {
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

module "meta_access_role" {
  source = "MODULE_PATH_GOES_HERE"

  organization_prefix = local.organization_prefix

  ci_cd_account_ids = [
    aws_organizations_account.ci_cd_dev.id,
    aws_organizations_account.ci_cd_prod.id
  ]
}
```
