# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../src/slack_notify'

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

    context 'when deployment starts' do
      it 'returns message with new format: "Deploy X to Y: Started"' do
        result = SlackNotify.notification_for_event(base_event)
        
        expect(result[:text]).to match(/^Deploy test-service to production: Started/)
        expect(result[:text]).to include('ami-12345678')
        expect(result[:text]).to include('test-123')
      end

      it 'returns nil when SkipNotifications is true' do
        event = base_event.dup
        input = JSON.parse(event['detail']['input'])
        input['DeployConfig'] = { 'SkipNotifications' => true }
        event['detail']['input'] = input.to_json
        
        result = SlackNotify.notification_for_event(event)
        expect(result[:text]).to be_nil
      end
    end

    context 'when deployment completes successfully' do
      it 'returns message with new format: "Deploy X to Y: Completed"' do
        event = base_event.dup
        event['detail']['status'] = 'SUCCEEDED'
        event['detail']['output'] = { 'Status' => 'complete' }.to_json
        
        result = SlackNotify.notification_for_event(event)
        
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
        
        result = SlackNotify.notification_for_event(event)
        
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
        
        result = SlackNotify.notification_for_event(event)
        
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
      result = SlackNotify.notification_for_cancel(cancel_event)
      
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
      result = SlackNotify.notification_for_undeploy(undeploy_event)
      
      expect(result[:text]).to match(/^Undeploy test-service from development: Started/)
    end

    context 'when UNDEPLOY_TECHNO is enabled' do
      before { ENV['UNDEPLOY_TECHNO'] = 'true' }
      before { ENV['TECHNO_BEATS'] = 'https://example.com/techno' }
      after { ENV['UNDEPLOY_TECHNO'] = nil }

      it 'includes techno beats in completion message' do
        event = undeploy_event.dup
        event['detail']['status'] = 'SUCCEEDED'
        event['detail']['output'] = { 'Status' => 'complete' }.to_json
        
        result = SlackNotify.notification_for_undeploy(event)
        
        expect(result[:text]).to match(/^Undeploy test-service from development: Completed/)
        expect(result[:blocks]).to be_an(Array)
        expect(result[:blocks].last[:text][:text]).to include('https://example.com/techno')
      end
    end
  end

  describe '.notify' do
    it 'posts message to Slack API' do
      stub = stub_request(:post, "https://slack.com/api/chat.postMessage")
        .with(
          body: hash_including('channel' => '#test-deployments'),
          headers: {
            'Authorization' => 'Bearer xoxb-test-token',
            'Content-Type' => 'application/json; charset=utf-8'
          }
        )
        .to_return(status: 200, body: { ok: true }.to_json)

      result = SlackNotify.notify(channel: '#test-deployments', text: 'Test message')
      
      expect(stub).to have_been_requested
      expect(result).to include('Successfully notified')
    end

    it 'raises error when Slack API returns error' do
      stub_request(:post, "https://slack.com/api/chat.postMessage")
        .to_return(status: 400, body: { ok: false, error: 'invalid_channel' }.to_json)

      expect {
        SlackNotify.notify(channel: '#test-deployments', text: 'Test message')
      }.to raise_error(/Error calling slack/)
    end

    it 'skips notification when text is nil' do
      result = SlackNotify.notify(channel: '#test-deployments', text: nil)
      expect(result).to eq('Skipping notification.')
    end
  end

  describe '.handler' do
    let(:deploy_event) do
      {
        'resources' => ["arn:aws:states:us-east-1:123456789012:execution:deploy:test-123"],
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
      stub_request(:post, "https://slack.com/api/chat.postMessage")
        .to_return(status: 200, body: { ok: true }.to_json)
    end

    it 'handles deploy state machine events' do
      result = SlackNotify.handler(event: deploy_event, context: {})
      expect(result).to include('Successfully notified')
    end

    it 'handles unknown state machine gracefully' do
      event = deploy_event.dup
      event['resources'] = ["arn:aws:states:us-east-1:123456789012:execution:unknown:test-123"]
      
      result = SlackNotify.handler(event: event, context: {})
      expect(result).to include('Unknown state function trigger')
    end
  end
end