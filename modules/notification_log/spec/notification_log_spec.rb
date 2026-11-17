# frozen_string_literal: true

require_relative 'spec_helper'
require 'aws-sdk-ec2'
require_relative '../src/notification_log'

RSpec.describe NotificationLog do
  let(:input) { { 'ServiceName' => 'carrot', 'AccountCanonicalSlug' => 'production', 'AmiId' => 'ami-0abc' } }
  let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }
  let(:sha) { '09c4f525a1b2c3d4e5f60718293a4b5c6d7e8f90' }

  def event_for(machine, status: 'RUNNING', input: self.input, output: nil)
    arn = "arn:aws:states:us-east-1:123456789012:execution:#{machine}:run-123"
    {
      'id' => 'evt-1',
      'account' => '123456789012',
      'region' => 'us-east-1',
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

  # What the Lambda says to its log group besides the notification.
  def stderr_of
    captured = StringIO.new
    original = $stderr
    $stderr = captured
    yield
    captured.string
  ensure
    $stderr = original
  end

  before do
    ec2.stub_responses(:describe_images, image(tags: [tag('BuildCommit', sha)]))
    allow(Aws::EC2::Client).to receive(:new).and_return(ec2)
  end

  def image(owner: '123456789012', tags: [])
    { images: [{ image_id: 'ami-0abc', owner_id: owner, tags: tags }] }
  end

  def tag(key, value) = { key: key, value: value }

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

  describe 'the commit the AMI was built from' do
    def note_for(event = event_for('deploy'))
      JSON.parse(logged(event).first)
    end

    it "adds the AMI's BuildCommit tag as commit" do
      ec2.stub_responses(:describe_images, image(tags: [tag('Name', 'carrot'), tag('BuildCommit', sha)]))
      expect(note_for).to include('ami' => 'ami-0abc', 'commit' => sha)
    end

    it 'asks about that one AMI, in the region the event came from' do
      ec2.stub_responses(:describe_images, image(tags: [tag('BuildCommit', sha)]))
      note_for(event_for('deploy').merge('region' => 'us-west-2'))
      expect(Aws::EC2::Client).to have_received(:new).with(hash_including(region: 'us-west-2'))
      expect(ec2.api_requests.map { |r| r[:params] }).to eq([{ image_ids: ['ami-0abc'] }])
    end

    it 'passes the tag through as is, so a dev build says in-dev' do
      ec2.stub_responses(:describe_images, image(tags: [tag('BuildCommit', 'in-dev')]))
      expect(note_for).to include('commit' => 'in-dev')
    end

    it 'leaves commit off, and says the AMI is untagged, when the owner is this account and there is no tag' do
      ec2.stub_responses(:describe_images, image(tags: [tag('Name', 'carrot')]))
      note = nil
      err = stderr_of { note = note_for }
      expect(note).not_to have_key('commit')
      expect(note).to include('phase' => 'started', 'ami' => 'ami-0abc')
      expect(err).to match(/ami-0abc has no BuildCommit tag/)
      expect(err).not_to match(/not the owner/)
    end

    it 'says it is not the owner, as a different problem from untagged, when another account owns the AMI' do
      ec2.stub_responses(:describe_images, image(owner: '999999999999', tags: []))
      note = nil
      err = stderr_of { note = note_for }
      expect(note).not_to have_key('commit')
      expect(err).to include('not the owner of ami-0abc (owner 999999999999, this account 123456789012); ' \
                             'tags are not visible to it')
      expect(err).not_to match(/no BuildCommit tag/)
    end

    it 'still logs the notification, and says why, when the lookup fails' do
      ec2.stub_responses(:describe_images, 'UnauthorizedOperation')
      note = nil
      err = stderr_of { note = note_for }
      expect(note).to include('phase' => 'started', 'ami' => 'ami-0abc')
      expect(note).not_to have_key('commit')
      expect(err).to match(/could not describe ami-0abc: Aws::EC2::Errors::UnauthorizedOperation/)
    end

    it 'still logs the notification when the AMI is not visible at all' do
      ec2.stub_responses(:describe_images, images: [])
      note = nil
      err = stderr_of { note = note_for }
      expect(note).to include('ami' => 'ami-0abc')
      expect(note).not_to have_key('commit')
      expect(err).to match(/ami-0abc not found/)
    end

    it 'does not look anything up when there is no AMI, as for an undeploy' do
      out, = logged(event_for('undeploy', input: input.merge('AmiId' => nil)))
      expect(JSON.parse(out)).not_to have_key('commit')
      expect(Aws::EC2::Client).not_to have_received(:new)
    end
  end
end
