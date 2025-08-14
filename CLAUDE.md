# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Deployomat is an AWS deployment automation tool that manages AMI deployments using blue/green deployment strategies. It's implemented as a **Terraform module published to the Terraform Registry** with Ruby-based AWS Lambda functions orchestrated by AWS Step Functions.

**Important**: This is a Terraform module, not a deployed application. Users import this module into their own Terraform configurations to set up deployomat in their AWS accounts.

## Architecture

### Core Components
- **Terraform Modules**: Located in `/modules/`, each module serves a specific purpose (deployomat, deploy_access_role, deployer_role, meta_access_role, slack_notifier)
- **Lambda Functions**: Ruby 2.7 functions in `modules/deployomat/src/` handle deploy, cancel, undeploy, and Slack notifications
- **Step Functions**: State machines in `modules/deployomat/state_machines/` orchestrate deployment workflows

### Key Files
- `modules/deployomat/src/lib.rb`: Core deployment logic and utilities
- `modules/deployomat/src/deploy.rb`: Main deployment handler
- `modules/deployomat/src/cancel.rb`: Cancellation and rollback logic
- `modules/deployomat/src/undeploy.rb`: Service undeployment logic
- `modules/deployomat/state_machines/deploy.json`: Main deployment workflow

## Development Commands

### Building Lambda Functions
Lambda functions are packaged using Terraform's `archive_file` data source. Pre-built zips are stored in `modules/*/build/` directories.

### Terraform Commands
```bash
# Initialize Terraform
terraform init

# Plan infrastructure changes
terraform plan

# Apply infrastructure changes
terraform apply

# Format Terraform files
terraform fmt -recursive
```

### Working with Ruby Code
- Ruby version: 2.7 (AWS Lambda runtime)
- Gemfile present for testing dependencies
- Code is zipped by Terraform during apply

### Testing Commands
```bash
# Install dependencies
bundle install

# Run all tests
bundle exec rspec

# Run tests for specific module
rake spec:slack_notifier
rake spec:deployomat  # (when tests are added)

# Run linting
bundle exec rubocop

# Run all checks (formatting, validation, linting, tests)
rake check

# Run tests with coverage report
bundle exec rspec --format documentation
```

## Key Patterns

### Deployment Flow
1. **Start**: Create new ASG from template, attach to target groups
2. **Health Check**: Validate instances are healthy
3. **Rollout**: Gradually shift traffic using weighted target groups
4. **Bake**: Monitor for configured duration
5. **Finish**: Clean up old resources

### State Management
- DynamoDB table stores deployment state
- Uses conditional checks to prevent race conditions
- Deployment IDs track individual deployments

### Cross-Account Access
- Uses assume role pattern with external IDs
- Service roles must be under `/${organization_prefix}/service-role` path
- ABAC with environment and service tags

### Resource Naming
- ASGs: `{service}-{timestamp}`
- Template resources: `{service}-template`
- Target groups: Managed via tags

## Important Considerations

### When Modifying Deploy Logic
- Check `modules/deployomat/src/lib.rb` for shared utilities
- Ensure state transitions are atomic in DynamoDB
- Handle both web services (with load balancers) and batch services

### When Updating State Machines
- State machine definitions are in `modules/deployomat/state_machines/`
- Changes require Terraform apply to update Step Functions
- Test error handling paths thoroughly

### Security
- Never log sensitive information (account IDs are okay, but not credentials)
- Always use assume role for cross-account access
- Respect service role path restrictions

### Error Handling
- Use `fail_deploy` for deployment failures
- Ensure proper cleanup in error paths
- Log errors with context for debugging

## Testing Approach

**We now have RSpec tests!** The project includes a comprehensive testing setup:

### Test Structure
- **Unit Tests**: Located in `modules/*/spec/` directories
- **Test Helpers**: Each module has a `spec_helper.rb` for configuration
- **Mocking**: WebMock for HTTP requests, RSpec mocks for AWS SDK

### Running Tests
1. **Before committing changes**: Run `bundle exec rspec` to ensure tests pass
2. **For specific modules**: Use `rake spec:slack_notifier` or `rake spec:deployomat`
3. **With linting**: Run `rake check` for full validation
4. **CI Pipeline**: CircleCI runs tests automatically on all branches and validates Terraform configurations

### Writing New Tests
- Follow existing patterns in `modules/slack_notifier/spec/slack_notify_spec.rb`
- Mock AWS SDK calls to avoid real AWS interactions
- Test both success and failure paths
- Include edge cases and error conditions

### Integration Testing
1. Test in development AWS account first
2. Verify state transitions in DynamoDB
3. Check CloudWatch logs for Lambda execution
4. Monitor Step Functions execution in AWS console

## Common Tasks

### Adding a New Deployment Feature
1. Update logic in `modules/deployomat/src/deploy.rb` or `lib.rb`
2. Write tests for the new functionality in `modules/*/spec/`
3. Modify state machine if workflow changes needed
4. Update DynamoDB state handling if new fields required
5. Document changes in CHANGELOG.md following the existing format
6. Users will import the new module version and run `terraform apply` in their infrastructure

### Updating CHANGELOG.md
**IMPORTANT**: Only add **user-facing changes** to CHANGELOG.md. Users of this Terraform module care about:
- ✅ New features they can use
- ✅ Bug fixes that affect their deployments
- ✅ Breaking changes they need to adapt to
- ✅ Changes to module inputs, outputs, or behavior

Do NOT add internal changes like:
- ❌ Test suite additions or improvements
- ❌ CI/CD pipeline changes
- ❌ Development documentation (CLAUDE.md, etc.)
- ❌ Code refactoring that doesn't change behavior
- ❌ Linting or formatting updates

Remember: CHANGELOG.md is for module consumers, not maintainers.

### Debugging Deployments
1. Check Step Functions execution history
2. Review CloudWatch logs for Lambda functions
3. Examine DynamoDB deployment state
4. Look for error messages in Slack notifications (if configured)

### Updating IAM Permissions
1. Modify relevant role module (deploy_access_role, deployer_role, meta_access_role)
2. Be mindful of cross-account trust relationships
3. Test permission changes in development first

## Git Commit Guidelines

### Every Commit Must Capture Human-Claude Interaction

**The commit template below is MANDATORY for ALL commits** - infrastructure changes, Ruby code updates, state machine modifications, documentation, everything. This captures how humans effectively guide Claude.

### When to Commit
Only commit when:
- ✅ Terraform validates successfully (if infrastructure changed)
- ✅ Ruby syntax is valid (if Lambda code changed)
- ✅ Human explicitly requests commit OR
- ✅ Reached major milestone

Never commit:
- ❌ Without capturing full interaction log
- ❌ With Terraform validation errors
- ❌ "Proactively" without meeting above criteria

### Commit Checklist
Before ANY commit:
- [ ] Did I run `terraform fmt -recursive` if Terraform files changed?
- [ ] Did I validate Terraform configuration with `terraform validate`?
- [ ] Did I check Ruby syntax if Lambda code changed?
- [ ] Did I search for existing patterns before writing code?
- [ ] Did I document any NEW patterns in this file?
- [ ] **Did I capture VERBATIM human-Claude interactions in commit message?**

### MANDATORY: Output Before EVERY Commit
You MUST output exactly:
```
📝 COMMIT READY CHECK:
☑️ Terraform formatted: [YES/NO/NA - only if .tf files changed]
☑️ Terraform valid: [YES/NO/NA - only if infrastructure changed]
☑️ Ruby syntax valid: [YES/NO/NA - only if Lambda code changed]
☑️ Documented new patterns: [YES/NO/NA - only if applicable]
☑️ FULL interaction log ready: [YES - X prompts captured VERBATIM]

[If ANY are NO: "❌ NOT ready - need to: (list required actions)"]
[If ALL are YES/NA: "✅ Ready to commit with COMPLETE Human-Claude interaction log."]
```

### Commit Message Template
```bash
# First, check what you modified:
git status
# Then add YOUR specific changes (not everything):
git add [specific files you changed]
# For multiple files:
git add modules/deployomat/src/lib.rb modules/deployomat/state_machines/deploy.json
# Commit with interaction log:
git commit -m "$(cat <<'EOF'
Brief description of what was done

[Technical changes made - e.g., Updated Lambda function, Modified state machine, Changed IAM permissions]

## Human-Claude Interaction Log

### Human prompts (VERBATIM - include typos, informal language, COMPLETE text):
1. "[Copy-paste ENTIRE first prompt, even if long]"
   → Claude: [What Claude did in response]
   
2. "[Copy-paste ENTIRE second prompt, don't summarize or clean up]"
   → Claude: [How Claude adjusted]

### Key decisions made:
- Human guided: [specific guidance provided]
- Claude discovered: [patterns found, existing code analyzed]

🤖 Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

**Note**: Avoid `git add -A` when multiple Claudes work in parallel - add only YOUR files.