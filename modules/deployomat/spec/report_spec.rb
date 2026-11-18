# frozen_string_literal: true

require_relative 'spec_helper'

# The Report step: what deploy.json hands it ($ whole, as AllInput) and what it hands back.
RSpec.describe LambdaFunctions::Handler, '.deploy Report' do
  include_context 'with deploy world'

  let(:execution_arn) { 'arn:aws:states:us-east-1:232340377988:execution:deploy:exec-1' }
  let(:input) do
    { 'AccountCanonicalSlug' => slug, 'ServiceName' => service, 'AmiId' => '$LatestMinus:1',
      'DeployConfig' => { 'SkipNotifications' => true },
      'StartDeploy' => { 'Status' => 'success',
                         'Ami' => { 'Id' => 'ami-0abc', 'Tags' => { 'BuildCommit' => 'abc' } } } }
  end

  def report(all_input)
    described_class.deploy(
      event: { 'Step' => 'Report', 'ExecutionArn' => execution_arn, 'AllInput' => all_input },
      context: nil
    )
  end

  it 'puts the finished event with the AMI Start resolved, and marks the outcome Reported' do
    result = report(input.merge('Outcome' => { 'Status' => 'complete' }))

    expect(result).to eq('Status' => 'complete', 'Reported' => true)
    expected = {
      'event_id' => 'exec-1/completed', 'phase' => 'completed', 'service' => service, 'account' => slug,
      'ami' => 'ami-0abc', 'ami_requested' => '$LatestMinus:1', 'ami_tags' => { 'BuildCommit' => 'abc' },
      'execution_arn' => execution_arn, 'skip_notifications' => true, 'errors' => []
    }
    expect(world.deploy_events).to contain_exactly(include(expected))
  end

  it 'needs nothing from the deploy account or state table' do
    report(input.merge('Outcome' => { 'Status' => 'complete' }))

    expect(world.calls(:get_item)).to be_empty
    expect(world.calls(:describe_images)).to be_empty
  end

  it 'reports a known failure with its errors' do
    result = report(input.merge('Outcome' => { 'Status' => 'fail', 'Error' => ['Service did not become healthy.'] }))

    expect(result).to include('Status' => 'fail', 'Reported' => true)
    expect(world.deploy_events.first).to include('phase' => 'failed', 'errors' => ['Service did not become healthy.'])
  end

  it 'reports a superseded deploy as aborted' do
    report(input.merge('Outcome' => { 'Status' => 'deploy_aborted', 'Error' => 'Deploy was cancelled.' }))

    expect(world.deploy_events.first).to include('phase' => 'aborted', 'errors' => ['Deploy was cancelled.'])
  end

  it 'reports a rollback with the error the state machine caught, before Start got an AMI' do
    caught = { 'Error' => 'Lambda.Unknown', 'Cause' => 'boom' }
    world.images['ami-0req'] = { tags: { 'BuildCommit' => 'def' } }

    result = report({ 'AccountCanonicalSlug' => slug, 'ServiceName' => service, 'AmiId' => 'ami-0req',
                      'Error' => caught, 'Outcome' => { 'Status' => 'fail', 'Failed' => true } })

    expect(result).to eq('Status' => 'fail', 'Failed' => true, 'Reported' => true)
    expect(world.deploy_events.first).to include(
      'phase' => 'failed', 'errors' => %w[Lambda.Unknown boom],
      'ami' => 'ami-0req', 'ami_tags' => { 'BuildCommit' => 'def' }
    )
  end

  it "keeps a Lambda error's message, not its stack trace, and caps a long cause" do
    lambda_cause = JSON.generate('errorMessage' => 'boom', 'errorType' => 'RuntimeError', 'stackTrace' => ['x'] * 50)
    report(input.merge('Error' => { 'Error' => 'RuntimeError', 'Cause' => lambda_cause },
                       'Outcome' => { 'Status' => 'fail', 'Failed' => true }))
    report(input.merge('Error' => { 'Error' => 'States.TaskFailed', 'Cause' => 'y' * 5000 },
                       'Outcome' => { 'Status' => 'fail', 'Failed' => true }))

    first, second = world.deploy_events
    expect(first['errors']).to eq(%w[RuntimeError boom])
    expect(second['errors'].last.length).to eq(500)
  end

  it 'names no AMI when Start never resolved a command' do
    report(input.except('StartDeploy').merge('Outcome' => { 'Status' => 'fail', 'Error' => ['No AMI'] }))

    expect(world.deploy_events.first).to include('ami' => nil, 'ami_requested' => '$LatestMinus:1', 'ami_tags' => {})
  end

  it 'is not Reported when EventBridge rejects the event' do
    world.fail_with(:put_events, 'AccessDeniedException')

    result = nil
    expect { result = report(input.merge('Outcome' => { 'Status' => 'complete' })) }.to output(/put_events/).to_stderr
    expect(result).to eq('Status' => 'complete', 'Reported' => false)
  end

  it 'is not Reported, and does not raise, on a state it cannot read' do
    expect(report(nil)).to eq('Reported' => false)
  end
end
