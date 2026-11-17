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
        'skip_notifications' => false, 'ami_tags' => { 'BuildCommit' => '09c4f525' }
      )
      expect(Time.iso8601(detail['time'])).to be_within(5).of(Time.now)
      expect(detail).not_to include('ami_requested')
    end

    it 'keeps the requested AmiId when it was a command that resolved to another AMI' do
      detail = described_class.detail(**base, ami: 'ami-0abc', ami_requested: '$LatestMinus:1')

      expect(detail).to include('ami' => 'ami-0abc', 'ami_requested' => '$LatestMinus:1')
    end

    it 'stringifies errors and defaults the optional fields' do
      detail = described_class.detail(**base, phase: 'failed', errors: [:boom, 'bad'])

      expect(detail).to include('event_id' => 'run-123/failed', 'ami' => nil, 'ami_tags' => {},
                                'errors' => %w[boom bad])
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
