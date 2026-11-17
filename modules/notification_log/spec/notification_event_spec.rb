# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../src/notification_event'

RSpec.describe NotificationEvent do
  let(:arn) { 'arn:aws:states:us-east-1:123456789012:execution:Deployomat-Deploy:run-123' }
  let(:deploy_input) do
    { 'ServiceName' => 'carrot', 'AccountCanonicalSlug' => 'production', 'AmiId' => 'ami-0abc' }
  end

  def sfn_event(status, input: deploy_input, output: nil, **detail)
    {
      'id' => 'evt-1',
      'time' => '2026-11-16T22:00:00Z',
      'detail' => {
        'executionArn' => arn,
        'name' => 'run-123',
        'status' => status,
        'input' => input.to_json,
        'output' => output&.to_json
      }.merge(detail.transform_keys(&:to_s))
    }
  end

  def build(event, kind = 'deploy')
    described_class.build(event, kind)
  end

  describe 'a deploy starting' do
    subject(:note) { build(sfn_event('RUNNING')) }

    it 'carries the whole contract' do
      expect(note).to eq(
        'schema' => 'teak.deploy.notification/1',
        'event_id' => 'evt-1',
        'time' => '2026-11-16T22:00:00Z',
        'kind' => 'deploy',
        'phase' => 'started',
        'service' => 'carrot',
        'account' => 'production',
        'ami' => 'ami-0abc',
        'execution' => 'run-123',
        'execution_arn' => arn,
        'errors' => [],
        'skip_notifications' => false
      )
    end

    it 'survives a JSON round trip, which is how the plugin reads it' do
      expect(JSON.parse(JSON.generate(note))).to eq(note)
    end
  end

  describe 'a SUCCEEDED execution' do
    it 'is completed when the output says complete' do
      note = build(sfn_event('SUCCEEDED', output: { 'Status' => 'complete' }))
      expect(note).to include('phase' => 'completed', 'errors' => [])
    end

    it 'is failed when the output says fail, with its errors' do
      output = { 'Status' => 'fail', 'Error' => ['health check timed out', 'rolled back'] }
      note = build(sfn_event('SUCCEEDED', output: output))
      expect(note).to include('phase' => 'failed', 'errors' => ['health check timed out', 'rolled back'])
    end

    it 'is aborted when the output says deploy_aborted' do
      note = build(sfn_event('SUCCEEDED', output: { 'Status' => 'deploy_aborted', 'Error' => ['superseded'] }))
      expect(note).to include('phase' => 'aborted', 'errors' => ['superseded'])
    end

    it 'is unknown, and says why, for an output status it does not recognise' do
      note = build(sfn_event('SUCCEEDED', output: { 'Status' => 'sideways' }))
      expect(note).to include('phase' => 'unknown')
      expect(note['errors'].first).to include('sideways')
    end

    it 'is unknown when there is no output at all' do
      expect(build(sfn_event('SUCCEEDED'))).to include('phase' => 'unknown')
    end
  end

  describe 'other statuses' do
    it 'maps FAILED to failed with the error and cause' do
      note = build(sfn_event('FAILED', error: 'States.TaskFailed', cause: 'lambda blew up'))
      expect(note).to include('phase' => 'failed', 'errors' => ['States.TaskFailed', 'lambda blew up'])
    end

    it 'maps FAILED without an error or cause to failed with none' do
      expect(build(sfn_event('FAILED'))).to include('phase' => 'failed', 'errors' => [])
    end

    %w[TIMED_OUT ABORTED].each do |status|
      it "maps #{status} to unknown and warns the state may be inconsistent" do
        note = build(sfn_event(status))
        expect(note).to include('phase' => 'unknown')
        expect(note['errors'].first).to include(status).and include('inconsistent')
      end
    end

    it 'ignores the UPDATE status, which nothing in deployomat emits' do
      expect(build(sfn_event('UPDATE'))).to be_nil
    end
  end

  describe 'kinds' do
    let(:cancel_input) { { 'ServiceName' => 'carrot', 'AccountCanonicalSlug' => 'production', 'Comment' => 'by hand' } }

    it 'passes the kind through' do
      expect(build(sfn_event('RUNNING'), 'undeploy')).to include('kind' => 'undeploy')
    end

    it 'has no ami for a cancel, whose input carries none' do
      expect(build(sfn_event('RUNNING', input: cancel_input), 'cancel')).to include('kind' => 'cancel', 'ami' => nil)
    end
  end

  describe 'nested cancels' do
    # The Input deploy.json hands CancelConcurrentDeploy and Rollback, and undeploy.json
    # hands its cancel: the cancel's own fields plus the parent's execution id.
    let(:nested_input) do
      {
        'AccountCanonicalSlug' => 'production',
        'ServiceName' => 'carrot',
        'Comment' => 'Rolling back deploy of carrot in production',
        'AWS_STEP_FUNCTIONS_STARTED_BY_EXECUTION_ID' => arn
      }
    end

    it 'drops every phase of a cancel another execution started' do
      statuses = { 'RUNNING' => nil, 'SUCCEEDED' => { 'Status' => 'complete' }, 'FAILED' => nil }
      statuses.each do |status, output|
        expect(build(sfn_event(status, input: nested_input, output: output), 'cancel')).to be_nil
      end
    end

    it 'keeps a cancel somebody started by hand' do
      by_hand = nested_input.reject { |key, _| key == 'AWS_STEP_FUNCTIONS_STARTED_BY_EXECUTION_ID' }
      expect(build(sfn_event('RUNNING', input: by_hand), 'cancel')).to include('phase' => 'started')
    end
  end

  describe 'input handling' do
    it 'passes SkipNotifications through' do
      input = deploy_input.merge('DeployConfig' => { 'SkipNotifications' => true })
      expect(build(sfn_event('RUNNING', input: input))).to include('skip_notifications' => true)
    end

    it 'says unknown rather than dropping an event whose input is unusable' do
      event = sfn_event('FAILED')
      event['detail']['input'] = 'not json'
      expect(build(event)).to include('service' => 'unknown', 'account' => 'unknown', 'phase' => 'failed')
      event['detail'].delete('input')
      expect(build(event)).to include('service' => 'unknown')
    end

    it 'copes with input that is JSON but not an object' do
      ['[]', '"text"', '3'].each do |json|
        event = sfn_event('RUNNING')
        event['detail']['input'] = json
        expect(build(event)).to include('phase' => 'started', 'service' => 'unknown')
      end
    end

    it 'stamps the time when the event has none' do
      event = sfn_event('RUNNING')
      event.delete('time')
      expect(Time.iso8601(build(event)['time'])).to be_within(60).of(Time.now)
    end
  end

  # fixtures/aws_documented_events.json holds the sample "Step Functions Execution Status
  # Change" events from AWS's documentation, copied verbatim (including its quirks, like the
  # "arn:aws::states" in the RUNNING sample) on 2026-11-16 from
  # https://docs.aws.amazon.com/step-functions/latest/dg/eventbridge-integration.html
  # Everything above is shaped by us; these are shaped by AWS. A captured event from a live
  # deploy should replace or join them once the module is applied.
  describe "AWS's documented events" do
    let(:documented) do
      JSON.parse(File.read(File.join(__dir__, 'fixtures', 'aws_documented_events.json')))
          .to_h { |event| [event.dig('detail', 'status'), event] }
    end

    it 'covers the five statuses the page shows' do
      expect(documented.keys).to contain_exactly('RUNNING', 'SUCCEEDED', 'FAILED', 'TIMED_OUT', 'ABORTED')
    end

    it 'maps each to a notification, carrying the event id and time through' do
      documented.each_value do |event|
        expect(build(event)).to include('event_id' => event['id'], 'time' => event['time'],
                                        'execution' => 'execution-name')
      end
    end

    it 'reads RUNNING as started and FAILED as failed with its error and cause' do
      expect(build(documented['RUNNING'])).to include('phase' => 'started', 'errors' => [])
      expect(build(documented['FAILED']))
        .to include('phase' => 'failed', 'errors' => ['ErrorCode', 'An error occurred.'])
    end

    it 'does not take a non-object output, or empty input, for a deploy result' do
      note = build(documented['SUCCEEDED'])
      expect(note).to include('phase' => 'unknown', 'service' => 'unknown', 'ami' => nil)
    end

    it 'treats TIMED_OUT and ABORTED as unknown, not as a clean finish' do
      expect(build(documented['TIMED_OUT'])).to include('phase' => 'unknown')
      expect(build(documented['ABORTED'])).to include('phase' => 'unknown')
    end
  end
end
