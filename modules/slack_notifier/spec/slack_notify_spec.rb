# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../src/slack_notify'
require_relative '../../deployomat/src/deploy_event'

RSpec.describe SlackNotify do
  describe '.notification_for_event' do
    let(:base_event) do
      {
        'detail' => {
          'executionArn' => 'arn:aws:states:us-east-1:123456789012:execution:deploy:test-123',
          'name' => 'test-123',
          'input' => {
            'ServiceName' => 'test-service',
            'AccountCanonicalSlug' => 'production',
            'AmiId' => 'ami-12345678'
          }.to_json,
          'status' => 'RUNNING'
        }
      }
    end

    context 'when deployment completes successfully' do
      it 'returns message with new format: "Deploy X to Y: Completed"' do
        event = base_event.dup
        event['detail']['status'] = 'SUCCEEDED'
        event['detail']['output'] = { 'Status' => 'complete' }.to_json

        result = described_class.notification_for_event(event)

        expect(result[:text]).to match(/^Deploy test-service to production: Completed/)
      end
    end

    context 'when deployment fails' do
      it 'returns message with new format: "Deploy X to Y: Failed"' do
        event = base_event.dup
        event['detail']['status'] = 'SUCCEEDED'
        event['detail']['output'] = {
          'Status' => 'fail',
          'Error' => ['Something went wrong', 'Check the logs']
        }.to_json

        result = described_class.notification_for_event(event)

        expect(result[:text]).to match(/^Deploy test-service to production: Failed/)
        expect(result[:text]).to include('Something went wrong')
        expect(result[:text]).to include('Check the logs')
      end
    end

    context 'when deployment is aborted' do
      it 'returns message with new format: "Deploy X to Y: Aborted"' do
        event = base_event.dup
        event['detail']['status'] = 'SUCCEEDED'
        event['detail']['output'] = {
          'Status' => 'deploy_aborted',
          'Error' => ['User cancelled deployment']
        }.to_json

        result = described_class.notification_for_event(event)

        expect(result[:text]).to match(/^Deploy test-service to production: Aborted/)
        expect(result[:text]).to include('User cancelled deployment')
      end
    end
  end

  describe '.notification_for_cancel' do
    let(:cancel_event) do
      {
        'detail' => {
          'executionArn' => 'arn:aws:states:us-east-1:123456789012:execution:cancel:test-456',
          'name' => 'test-456',
          'input' => {
            'ServiceName' => 'test-service',
            'AccountCanonicalSlug' => 'staging'
          }.to_json,
          'status' => 'RUNNING'
        }
      }
    end

    it 'returns message with new format: "Cancel deployment X to Y: Started"' do
      result = described_class.notification_for_cancel(cancel_event)

      expect(result[:text]).to match(/^Cancel deployment test-service to staging: Started/)
    end
  end

  describe '.notification_for_undeploy' do
    let(:undeploy_event) do
      {
        'detail' => {
          'executionArn' => 'arn:aws:states:us-east-1:123456789012:execution:undeploy:test-789',
          'name' => 'test-789',
          'input' => {
            'ServiceName' => 'test-service',
            'AccountCanonicalSlug' => 'development'
          }.to_json,
          'status' => 'RUNNING'
        }
      }
    end

    it 'returns message with new format: "Undeploy X from Y: Started"' do
      result = described_class.notification_for_undeploy(undeploy_event)

      expect(result[:text]).to match(/^Undeploy test-service from development: Started/)
    end

    context 'when UNDEPLOY_TECHNO is enabled' do
      before do
        ENV['UNDEPLOY_TECHNO'] = 'true'
        ENV['TECHNO_BEATS'] = 'https://example.com/techno'
      end

      after { ENV['UNDEPLOY_TECHNO'] = nil }

      it 'includes techno beats in completion message' do
        event = undeploy_event.dup
        event['detail']['status'] = 'SUCCEEDED'
        event['detail']['output'] = { 'Status' => 'complete' }.to_json

        result = described_class.notification_for_undeploy(event)

        expect(result[:text]).to match(/^Undeploy test-service from development: Completed/)
        expect(result[:blocks]).to be_an(Array)
        expect(result[:blocks].last[:text][:text]).to include('https://example.com/techno')
      end
    end
  end

  describe '.notify' do
    it 'posts message to Slack API' do
      stub = stub_request(:post, 'https://slack.com/api/chat.postMessage')
             .with(
               body: hash_including('channel' => '#test-deployments'),
               headers: {
                 'Authorization' => 'Bearer xoxb-test-token',
                 'Content-Type' => 'application/json; charset=utf-8'
               }
             )
             .to_return(status: 200, body: { ok: true }.to_json)

      result = described_class.notify(channel: '#test-deployments', text: 'Test message')

      expect(stub).to have_been_requested
      expect(result).to include('Successfully notified')
    end

    it 'raises error when Slack API returns error' do
      stub_request(:post, 'https://slack.com/api/chat.postMessage')
        .to_return(status: 400, body: { ok: false, error: 'invalid_channel' }.to_json)

      expect do
        described_class.notify(channel: '#test-deployments', text: 'Test message')
      end.to raise_error(/Error calling slack/)
    end

    it 'skips notification when text is nil' do
      result = described_class.notify(channel: '#test-deployments', text: nil)
      expect(result).to eq('Skipping notification.')
    end
  end

  describe '.notification_for_deploy_event' do
    let(:note) do
      detail = Deployomat::DeployEvent.detail(
        kind: 'deploy', phase: 'started', service: 'audience', account: 'workload-prod',
        execution_arn: 'arn:aws:states:us-east-1:1:execution:deploy:run-1', ami: 'ami-0abc',
        ami_tags: { 'BuildCommit' => '09c4f525c0ffee' }
      )
      JSON.parse(JSON.generate(detail))
    end

    def text(overrides = {})
      described_class.notification_for_deploy_event(note.merge(overrides))[:text]
    end

    it 'reads like the status-event message, with the short commit after the AMI' do
      expect(text).to start_with('Deploy audience to workload-prod: Started (AMI <')
      expect(text).to include('|ami-0abc>, commit 09c4f52, Execution <')
      expect(text).to end_with('|run-1>)')
    end

    it 'leaves the commit out when the tag is not a sha' do
      expect(text('ami_tags' => { 'BuildCommit' => 'in-dev' })).not_to include('commit')
      expect(text('ami_tags' => {})).not_to include('commit')
    end

    it 'names the requested AMI when no AMI was resolved' do
      expect(text('ami' => nil, 'ami_requested' => '$LatestMinus:1',
                  'ami_tags' => {})).to include('(AMI $LatestMinus:1, Execution')
    end

    it 'adds the errors to a failure or abort' do
      expect(text('phase' => 'failed',
                  'errors' => %w[one two])).to include(': Failed (AMI').and end_with("\n\none\ntwo")
      expect(text('phase' => 'aborted', 'errors' => ['superseded'])).to end_with("\n\nsuperseded")
    end

    it 'skips Rollout\'s progress events' do
      expect(text('phase' => 'progress', 'status' => 'wait', 'progress' => 40)).to be_nil
    end

    it 'skips a start or completion with SkipNotifications, but never a failure' do
      expect(text('skip_notifications' => true)).to be_nil
      expect(text('skip_notifications' => true, 'phase' => 'completed')).to be_nil
      expect(text('skip_notifications' => true, 'phase' => 'failed')).to include('Failed')
    end
  end

  describe '.handler' do
    let(:deploy_event) do
      {
        'resources' => ['arn:aws:states:us-east-1:123456789012:execution:deploy:test-123'],
        'detail' => {
          'executionArn' => 'arn:aws:states:us-east-1:123456789012:execution:deploy:test-123',
          'name' => 'test-123',
          'input' => {
            'ServiceName' => 'api-service',
            'AccountCanonicalSlug' => 'production',
            'AmiId' => 'ami-abcdef123'
          }.to_json,
          'status' => 'RUNNING'
        }
      }
    end

    before do
      stub_request(:post, 'https://slack.com/api/chat.postMessage')
        .to_return(status: 200, body: { ok: true }.to_json)
    end

    it 'reports deploy status events deployomat did not: a timeout, an unmarked failure' do
      [{ 'status' => 'TIMED_OUT' }, { 'status' => 'FAILED', 'error' => 'States.Runtime' }].each do |change|
        event = deploy_event.merge('detail' => deploy_event['detail'].merge(change))
        expect(described_class.handler(event: event, context: {})).to include('Successfully notified')
      end
    end

    it 'skips deploy status events deployomat reported, without calling Slack' do
      reported = [
        deploy_event,
        deploy_event.merge('detail' => deploy_event['detail'].merge(
          'status' => 'SUCCEEDED', 'output' => { 'Status' => 'complete', 'Reported' => true }.to_json
        )),
        deploy_event.merge('detail' => deploy_event['detail'].merge('status' => 'FAILED',
                                                                    'error' => 'Deployomat.Reported'))
      ]

      reported.each do |event|
        expect(described_class.handler(event: event,
                                       context: {})).to eq('Skipping notification: deployomat reported it.')
      end
      expect(a_request(:post, 'https://slack.com/api/chat.postMessage')).not_to have_been_made
    end

    it 'posts nothing for a deploy-source event that is not a deploy notification' do
      %w[cancel undeploy].each do |kind|
        detail = Deployomat::DeployEvent.detail(
          kind: kind, phase: 'started', service: 'api-service', account: 'production',
          execution_arn: "arn:aws:states:us-east-1:123456789012:execution:#{kind}:test-123"
        )
        event = { 'source' => 'omat.deployomat', 'resources' => [detail['execution_arn']],
                  'detail' => JSON.parse(JSON.generate(detail)) }
        expect(described_class.handler(event: event,
                                       context: {})).to eq('Skipping notification: not a deploy notification.')
      end
      odd = { 'source' => 'omat.deployomat', 'resources' => ['x'],
              'detail' => { 'schema' => 'other/2', 'kind' => 'deploy' } }
      expect(described_class.handler(event: odd,
                                     context: {})).to eq('Skipping notification: not a deploy notification.')
      expect(a_request(:post, 'https://slack.com/api/chat.postMessage')).not_to have_been_made
    end

    it 'reports an aborted deploy from the backstop, whose Error is a string' do
      event = deploy_event.merge('detail' => deploy_event['detail'].merge(
        'status' => 'SUCCEEDED',
        'output' => { 'Status' => 'deploy_aborted',
                      'Error' => 'Deploy was cancelled due to a superseding deploy.' }.to_json
      ))
      expect(described_class.handler(event: event, context: {})).to include('Successfully notified')
      expect(a_request(:post, 'https://slack.com/api/chat.postMessage')
        .with { |req| JSON.parse(req.body)['text'].end_with?("\n\nDeploy was cancelled due to a superseding deploy.") })
        .to have_been_made
    end

    it 'treats output that is JSON but not an object as unreported' do
      event = deploy_event.merge('detail' => deploy_event['detail'].merge('status' => 'SUCCEEDED', 'output' => '[1]'))
      expect(described_class.reported_by_deployomat?(event)).to be(false)
    end

    it "posts deployomat's own deploy event" do
      detail = Deployomat::DeployEvent.detail(
        kind: 'deploy', phase: 'completed', service: 'api-service', account: 'production',
        execution_arn: 'arn:aws:states:us-east-1:123456789012:execution:deploy:test-123', ami: 'ami-0abc'
      )
      event = { 'source' => 'omat.deployomat', 'detail-type' => 'Deployomat Deploy',
                'resources' => [detail['execution_arn']], 'detail' => JSON.parse(JSON.generate(detail)) }

      expect(described_class.handler(event: event, context: {})).to include('Successfully notified')
      expect(a_request(:post, 'https://slack.com/api/chat.postMessage')
        .with { |req| JSON.parse(req.body)['text'].start_with?('Deploy api-service to production: Completed') })
        .to have_been_made
    end

    it 'handles unknown state machine gracefully' do
      event = deploy_event.dup
      event['resources'] = ['arn:aws:states:us-east-1:123456789012:execution:unknown:test-123']

      result = described_class.handler(event: event, context: {})
      expect(result).to include('Unknown state function trigger')
    end
  end
end
