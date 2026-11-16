# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../src/notification_log'

RSpec.describe NotificationLog do
  let(:input) { { 'ServiceName' => 'carrot', 'AccountCanonicalSlug' => 'production', 'AmiId' => 'ami-0abc' } }

  def event_for(machine, status: 'RUNNING', input: self.input, output: nil)
    arn = "arn:aws:states:us-east-1:123456789012:execution:#{machine}:run-123"
    {
      'id' => 'evt-1',
      'time' => '2026-11-16T22:00:00Z',
      'resources' => [arn],
      'detail' => {
        'executionArn' => arn, 'name' => 'run-123', 'status' => status,
        'input' => input.to_json, 'output' => output&.to_json
      }
    }
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
    out, = logged(event_for('deploy'))
    expect(out.lines.size).to eq(1)
    note = JSON.parse(out)
    expect(note).to include('schema' => 'teak.deploy.notification/1', 'kind' => 'deploy', 'phase' => 'started',
                            'service' => 'carrot', 'ami' => 'ami-0abc')
  end

  it 'tells the three state machines apart' do
    kinds = %w[deploy undeploy cancel].map { |machine| JSON.parse(logged(event_for(machine)).first)['kind'] }
    expect(kinds).to eq(%w[deploy undeploy cancel])
  end

  it 'logs a failed deploy that finished SUCCEEDED with its errors' do
    out, = logged(event_for('deploy', status: 'SUCCEEDED', output: { 'Status' => 'fail', 'Error' => ['unhealthy'] }))
    expect(JSON.parse(out)).to include('phase' => 'failed', 'errors' => ['unhealthy'])
  end

  it 'logs nothing for a cancel another execution started' do
    parent_arn = 'arn:aws:states:us-east-1:1:execution:deploy:p'
    nested = input.merge('AWS_STEP_FUNCTIONS_STARTED_BY_EXECUTION_ID' => parent_arn)
    out, result = logged(event_for('cancel', input: nested))
    expect(out).to eq('')
    expect(result).to eq('Skipping notification.')
  end

  it 'logs nothing, and says so, for an execution of some other state machine' do
    out, result = logged(event_for('somebody-elses'))
    expect(out).not_to include('teak.deploy.notification')
    expect(result).to start_with('Unknown state machine trigger')
  end
end
