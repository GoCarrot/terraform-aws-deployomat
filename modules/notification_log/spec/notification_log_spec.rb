# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../src/notification_log'
require_relative '../../deployomat/src/deploy_event'

RSpec.describe NotificationLog do
  let(:input) { { 'ServiceName' => 'carrot', 'AccountCanonicalSlug' => 'production', 'AmiId' => 'ami-0abc' } }

  def event_for(machine, status: 'RUNNING', input: self.input, output: nil, error: nil)
    arn = "arn:aws:states:us-east-1:123456789012:execution:#{machine}:run-123"
    {
      'id' => 'evt-1',
      'time' => '2026-11-16T22:00:00Z',
      'source' => 'aws.states',
      'resources' => [arn],
      'detail' => {
        'executionArn' => arn, 'name' => 'run-123', 'status' => status,
        'input' => input.to_json, 'output' => output&.to_json, 'error' => error
      }
    }
  end

  # What deployomat puts, built by its own DeployEvent, as EventBridge delivers it.
  def deploy_event(phase: 'started', **fields)
    arn = 'arn:aws:states:us-east-1:123456789012:execution:deploy:run-123'
    detail = Deployomat::DeployEvent.detail(
      kind: 'deploy', phase: phase, service: 'carrot', account: 'production', execution_arn: arn,
      ami: 'ami-0abc', ami_tags: { 'BuildCommit' => '09c4f525' }, **fields
    )
    { 'id' => 'evt-2', 'source' => 'omat.deployomat', 'detail-type' => 'Deployomat Deploy', 'resources' => [arn],
      'detail' => JSON.parse(JSON.generate(detail)) }
  end

  def logged(event)
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    result = described_class.handler(event: event, context: nil)
    [captured.string, result]
  ensure
    $stdout = original
  end

  it 'writes one bare JSON line for a deploy, which parses back to the notification' do
    out, = logged(event_for('deploy', status: 'TIMED_OUT'))
    expect(out.lines.size).to eq(1)
    note = JSON.parse(out)
    expect(note).to include('schema' => 'teak.deploy.notification/1', 'kind' => 'deploy', 'phase' => 'unknown',
                            'service' => 'carrot', 'ami' => 'ami-0abc')
  end

  it 'tells the three state machines apart' do
    kinds = %w[deploy undeploy cancel].map do |machine|
      JSON.parse(logged(event_for(machine, status: 'FAILED')).first)['kind']
    end
    expect(kinds).to eq(%w[deploy undeploy cancel])
  end

  describe "deployomat's own deploy events" do
    it 'are written as they arrive, tags and all' do
      event = deploy_event
      out, result = logged(event)

      expect(JSON.parse(out)).to eq(event['detail'])
      expect(JSON.parse(out)).to include('ami_tags' => { 'BuildCommit' => '09c4f525' }, 'event_id' => 'run-123/started')
      expect(result).to eq('Logged started for carrot')
    end

    it 'write a progress event as it arrives, step and line included' do
      event = deploy_event(phase: 'progress', step: 'Rollout', status: :wait,
                           progress: 'Shifted 40% of traffic to the new ASG')
      out, result = logged(event)

      expect(JSON.parse(out)).to eq(event['detail'])
      expect(result).to eq('Logged progress for carrot')
    end

    it 'are not written when the detail is not a notification' do
      event = deploy_event.merge('detail' => { 'schema' => 'something/2' })
      out, result = logged(event)

      expect(out).not_to include('teak.deploy.notification')
      expect(result).to eq('Unknown deploy event')
    end
  end

  describe 'status events as a backstop for deploys' do
    def skipped?(event)
      out, result = logged(event)
      out.empty? && result == 'Skipping notification: deployomat reported it.'
    end

    it 'skips what deployomat reported: the start, a Reported ending, a Deployomat.Reported failure' do
      expect(skipped?(event_for('deploy'))).to be(true)
      expect(skipped?(event_for('deploy', status: 'SUCCEEDED',
                                          output: { 'Status' => 'complete', 'Reported' => true }))).to be(true)
      expect(skipped?(event_for('deploy', status: 'FAILED', error: 'Deployomat.Reported'))).to be(true)
    end

    it 'logs what deployomat did not' do
      unreported = [
        event_for('deploy', status: 'SUCCEEDED', output: { 'Status' => 'complete' }),
        event_for('deploy', status: 'SUCCEEDED', output: { 'Status' => 'complete', 'Reported' => false }),
        event_for('deploy', status: 'FAILED', error: 'States.Runtime'),
        event_for('deploy', status: 'FAILED'),
        event_for('deploy', status: 'TIMED_OUT'),
        event_for('deploy', status: 'ABORTED')
      ]

      phases = unreported.map { |event| JSON.parse(logged(event).first)['phase'] }
      expect(phases).to eq(%w[completed completed failed failed unknown unknown])
    end

    it 'does the same for cancels and undeploys' do
      %w[cancel undeploy].each do |machine|
        expect(skipped?(event_for(machine))).to be(true)
        expect(skipped?(event_for(machine, status: 'SUCCEEDED',
                                           output: { 'Status' => 'complete', 'Reported' => true }))).to be(true)
        expect(skipped?(event_for(machine, status: 'FAILED', error: 'Deployomat.Reported'))).to be(true)

        notes = [event_for(machine, status: 'SUCCEEDED', output: { 'Status' => 'complete' }),
                 event_for(machine, status: 'FAILED', error: 'States.Runtime'),
                 event_for(machine, status: 'TIMED_OUT'), event_for(machine, status: 'ABORTED')]
                .map { |event| JSON.parse(logged(event).first) }
        expect(notes.map { |n| n.values_at('kind', 'phase') })
          .to eq([[machine, 'completed'], [machine, 'failed'], [machine, 'unknown'], [machine, 'unknown']])
      end
    end

    it "logs deployomat's own cancel and undeploy events as they arrive" do
      %w[cancel undeploy].each do |kind|
        arn = "arn:aws:states:us-east-1:123456789012:execution:#{kind}:run-123"
        detail = JSON.parse(JSON.generate(Deployomat::DeployEvent.detail(
                                            kind: kind, phase: 'completed', service: 'carrot', account: 'production',
                                            execution_arn: arn
                                          )))
        out, result = logged('source' => 'omat.deployomat', 'resources' => [arn], 'detail' => detail)

        expect(JSON.parse(out)).to eq(detail)
        expect(result).to eq('Logged completed for carrot')
      end
    end
  end

  it 'logs a failed deploy that finished SUCCEEDED with its errors' do
    out, = logged(event_for('deploy', status: 'SUCCEEDED', output: { 'Status' => 'fail', 'Error' => ['unhealthy'] }))
    expect(JSON.parse(out)).to include('phase' => 'failed', 'errors' => ['unhealthy'])
  end

  it 'logs nothing for a cancel another execution started' do
    parent_arn = 'arn:aws:states:us-east-1:1:execution:deploy:p'
    nested = input.merge('AWS_STEP_FUNCTIONS_STARTED_BY_EXECUTION_ID' => parent_arn)
    out, result = logged(event_for('cancel', status: 'SUCCEEDED', output: { 'Status' => 'complete' }, input: nested))
    expect(out).to eq('')
    expect(result).to eq('Skipping notification.')
  end

  it 'logs nothing, and says so, for an execution of some other state machine' do
    out, result = logged(event_for('somebody-elses'))
    expect(out).not_to include('teak.deploy.notification')
    expect(result).to start_with('Unknown state machine trigger')
  end
end
