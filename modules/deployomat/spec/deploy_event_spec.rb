# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../src/deploy_event'

RSpec.describe Deployomat::DeployEvent do
  let(:execution_arn) { 'arn:aws:states:us-east-1:232340377988:execution:deploy:run-123' }

  describe '.ami_tags' do
    let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }

    it 'returns every tag on the AMI' do
      ec2.stub_responses(:describe_images, images: [{
                           image_id: 'ami-0abc', tags: [{ key: 'BuildCommit', value: '09c4f525' },
                                                        { key: 'Service', value: 'audience' }]
                         }])

      expect(described_class.ami_tags('ami-0abc',
                                      client: ec2)).to eq('BuildCommit' => '09c4f525', 'Service' => 'audience')
      expect(ec2.api_requests.first[:params]).to eq(image_ids: ['ami-0abc'])
    end

    it 'is empty for an untagged AMI' do
      ec2.stub_responses(:describe_images, images: [{ image_id: 'ami-0abc' }])

      expect(described_class.ami_tags('ami-0abc', client: ec2)).to eq({})
    end

    it 'is empty, with a stderr line, when the AMI is not found' do
      ec2.stub_responses(:describe_images, images: [])

      expect { expect(described_class.ami_tags('ami-0abc', client: ec2)).to eq({}) }
        .to output(/ami-0abc not found/).to_stderr
    end

    it 'is empty, with a stderr line, when the call fails' do
      ec2.stub_responses(:describe_images, 'UnauthorizedOperation')

      expect { expect(described_class.ami_tags('ami-0abc', client: ec2)).to eq({}) }
        .to output(/could not describe ami-0abc: .*UnauthorizedOperation/).to_stderr
    end

    it 'does not look up something that is not an AMI id' do
      expect(described_class.ami_tags(nil, client: ec2)).to eq({})
      expect(described_class.ami_tags('$LatestMinus:1', client: ec2)).to eq({})
      expect(ec2.api_requests).to be_empty
    end
  end

  describe '.ami_fields' do
    let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }

    before { allow(described_class).to receive(:ec2_client).and_return(ec2) }

    it 'takes the AMI Start resolved, as Ruby or as JSON hands it back' do
      expect(described_class.ami_fields({ Id: 'ami-0abc', Tags: { 'A' => 'b' } }, '$LatestMinus:1'))
        .to eq(ami: 'ami-0abc', ami_tags: { 'A' => 'b' })
      expect(described_class.ami_fields({ 'Id' => 'ami-0abc', 'Tags' => nil }, '$LatestMinus:1'))
        .to eq(ami: 'ami-0abc', ami_tags: {})
      expect(ec2.api_requests).to be_empty
    end

    it 'falls back to the requested AmiId when it is an AMI id, with its tags' do
      ec2.stub_responses(:describe_images, images: [{ image_id: 'ami-0req', tags: [{ key: 'A', value: 'b' }] }])

      expect(described_class.ami_fields(nil, 'ami-0req')).to eq(ami: 'ami-0req', ami_tags: { 'A' => 'b' })
      expect(described_class.ami_fields(nil, '$LatestMinus:1')).to eq(ami: nil, ami_tags: {})
    end
  end

  describe '.detail' do
    let(:base) do
      { kind: 'deploy', phase: 'started', service: 'audience', account: 'workload-prod', execution_arn: execution_arn }
    end

    it 'is a teak deploy notification with the AMI and its tags' do
      detail = described_class.detail(**base, ami: 'ami-0abc', ami_tags: { 'BuildCommit' => '09c4f525' })

      expect(detail).to include(
        'schema' => 'teak.deploy.notification/1', 'event_id' => 'run-123/started', 'kind' => 'deploy',
        'phase' => 'started', 'service' => 'audience', 'account' => 'workload-prod', 'ami' => 'ami-0abc',
        'execution' => 'run-123', 'execution_arn' => execution_arn, 'errors' => [],
        'skip_notifications' => false, 'ami_tags' => { 'BuildCommit' => '09c4f525' }, 'step' => nil, 'status' => nil,
        'progress' => nil
      )
      expect(Time.iso8601(detail['time'])).to be_within(5).of(Time.now)
      expect(detail).not_to include('ami_requested')
    end

    it 'keeps the requested AmiId when it was a command that resolved to another AMI' do
      detail = described_class.detail(**base, ami: 'ami-0abc', ami_requested: '$LatestMinus:1')

      expect(detail).to include('ami' => 'ami-0abc', 'ami_requested' => '$LatestMinus:1')
    end

    it 'keeps one event_id per progress, since a rollout puts several' do
      detail = described_class.detail(**base, phase: 'progress', progress: 40)

      expect(detail).to include('event_id' => 'run-123/progress/40', 'progress' => 40)
    end

    it 'stringifies errors and defaults the optional fields' do
      detail = described_class.detail(**base, phase: 'failed', errors: [:boom, 'bad'])

      expect(detail).to include('event_id' => 'run-123/failed', 'ami' => nil, 'ami_tags' => {},
                                'errors' => %w[boom bad])
    end
  end

  describe 'the clients' do
    # Stubbed, so building a client doesn't go looking for credentials.
    around do |example|
      had_stubs = Aws.config.key?(:stub_responses)
      Aws.config.update(stub_responses: true) unless had_stubs
      example.run
    ensure
      Aws.config.delete(:stub_responses) unless had_stubs
    end

    it 'are built once, and give up within seconds between them' do
      described_class.instance_variable_set(:@ec2_client, nil)
      described_class.instance_variable_set(:@events_client, nil)

      ec2 = described_class.ec2_client.config
      events = described_class.events_client.config
      worst = ->(c) { (c.retry_limit + 1) * (c.http_open_timeout + c.http_read_timeout) }

      expect(ec2).to have_attributes(retry_limit: 0, http_open_timeout: 1, http_read_timeout: 2)
      expect(events).to have_attributes(retry_limit: 1, http_open_timeout: 1, http_read_timeout: 2)
      expect(worst[ec2] + worst[events]).to be <= 10
      expect(described_class.ec2_client.config).to be(ec2)
      expect(described_class.events_client.config).to be(events)
    end
  end

  describe Deployomat::DeployEvent::Reporter do
    let(:events) { Aws::EventBridge::Client.new(stub_responses: true) }
    let(:reporter) do
      described_class.new(execution_arn: execution_arn, service: 'audience', account: 'workload-prod', step: 'Rollout',
                          ami_requested: '$LatestMinus:1', ami: { 'Id' => 'ami-0abc', 'Tags' => { 'A' => 'b' } })
    end

    before { allow(Deployomat::DeployEvent).to receive(:events_client).and_return(events) }

    def put
      events.api_requests.map { |r| JSON.parse(r[:params][:entries].first[:detail]) }
    end

    it 'puts an event with any phase, naming the step, and says it landed' do
      expect(reporter.emit('rollout_step', status: :wait)).to be(true)

      expected = {
        'phase' => 'rollout_step', 'step' => 'Rollout', 'status' => 'wait', 'event_id' => 'run-123/rollout_step',
        'ami' => 'ami-0abc', 'ami_tags' => { 'A' => 'b' }, 'ami_requested' => '$LatestMinus:1'
      }
      expect(put).to contain_exactly(include(expected))
    end

    it 'marks the result it ends the run with, keeping the result as the step returned it' do
      expect(reporter.failed(Status: :fail, Error: ['boom'])).to eq(Status: :fail, Error: ['boom'], Reported: true)
      expect(reporter.completed(Status: :complete)).to eq(Status: :complete, Reported: true)

      expect(put.map { |d| d.values_at('phase', 'status', 'errors') })
        .to eq([['failed', 'fail', ['boom']], ['completed', 'complete', []]])
    end

    it 'says why a deploy was aborted when the step gave no error' do
      reporter.aborted(Status: :deploy_aborted)

      expect(put.first['errors']).to eq([described_class::CANCELLED])
    end

    it 'puts nothing for a run on an older definition, which passes no ExecutionArn' do
      old_run = described_class.for_step('ServiceName' => 'audience', 'Step' => 'Finish')

      expect(old_run.completed(Status: :complete)).to eq(Status: :complete, Reported: false)
      expect(events.api_requests).to be_empty
    end

    it 'does not raise when building the event goes wrong' do
      allow(Deployomat::DeployEvent).to receive(:detail).and_raise(ArgumentError, 'bad')

      expect { expect(reporter.emit('started')).to be(false) }.to output(/could not put started/).to_stderr
    end

    it 'takes SkipNotifications from deploy.json, or from Start\'s own DeployConfig' do
      run = { 'ExecutionArn' => execution_arn, 'ServiceName' => 's' }
      later = described_class.for_step(run.merge('SkipNotifications' => true))
      start = described_class.for_step(run.merge('AllInput' => { 'DeployConfig' => { 'SkipNotifications' => true } }))
      later.emit('a')
      start.emit('b')

      expect(put.map { |d| d['skip_notifications'] }).to eq([true, true])
    end
  end

  describe '.publish' do
    let(:events) { Aws::EventBridge::Client.new(stub_responses: true) }
    let(:detail) do
      described_class.detail(kind: 'deploy', phase: 'completed', service: 'audience', account: 'workload-prod',
                             execution_arn: execution_arn, ami: 'ami-0abc')
    end

    it 'puts one entry and says it landed' do
      events.stub_responses(:put_events, failed_entry_count: 0, entries: [{ event_id: 'e-1' }])

      expect(described_class.publish(detail, client: events)).to be(true)

      entry = events.api_requests.first[:params][:entries].first
      expect(entry).to include(source: 'omat.deployomat', detail_type: 'Deployomat Deploy', resources: [execution_arn])
      expect(JSON.parse(entry[:detail])).to eq(detail)
    end

    it 'is false when EventBridge answers with a failed entry' do
      events.stub_responses(:put_events, failed_entry_count: 1,
                                         entries: [{ error_code: 'AccessDeniedException', error_message: 'no' }])

      expect { expect(described_class.publish(detail, client: events)).to be(false) }
        .to output(%r{rejected run-123/completed: AccessDeniedException}).to_stderr
    end

    it 'is false when the call raises' do
      events.stub_responses(:put_events, 'ThrottlingException')

      expect { expect(described_class.publish(detail, client: events)).to be(false) }
        .to output(%r{put_events failed for run-123/completed}).to_stderr
    end
  end
end
