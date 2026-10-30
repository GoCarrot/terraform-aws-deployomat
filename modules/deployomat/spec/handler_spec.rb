# frozen_string_literal: true

require_relative 'spec_helper'

# Each handler builds a Deployomat::Config before it does anything else. Ruby 3 no longer
# turns a positional Hash into keywords, so a bad call there fails every step of every deploy.
RSpec.describe LambdaFunctions::Handler do
  include_context 'with stubbed aws'

  def event(extra = {})
    { 'AccountCanonicalSlug' => slug, 'ServiceName' => service, 'DeployId' => 'exec-1' }.merge(extra)
  end

  describe '.cancel' do
    it 'fails a Start when nothing is deploying' do
      expect(described_class.cancel(event: event('Step' => 'Start'), context: nil)).to eq(:fail)
    end

    it 'fails a Finish when nothing is deploying' do
      result = described_class.cancel(event: event('Step' => 'Finish'), context: nil)

      expect(result).to include(Status: :fail)
      expect(dynamo_calls.length).to eq(1)
    end
  end

  describe '.deploy' do
    it 'rejects an unexpected Step' do
      result = described_class.deploy(event: event('Step' => 'Bogus'), context: nil)

      expect(result).to eq(Status: :fail, Error: ["Unexpected step: 'Bogus'"])
    end

    it 'builds a Config for a Finish' do
      allow(Deployomat::FinishDeploy).to receive(:new).and_call_original
      allow_any_instance_of(Deployomat::FinishDeploy).to receive(:call).and_return(Status: :complete) # rubocop:disable RSpec/AnyInstance

      result = described_class.deploy(event: event('Step' => 'Finish'), context: nil)

      expect(result).to eq(Status: :complete)
      expect(Deployomat::FinishDeploy).to have_received(:new).with(
        have_attributes(deploy_id: 'deploy-exec-1', primary_key: "#{slug}.#{service}"),
        allow_undeploy: nil, automatic_undeploy_minutes: nil
      )
    end
  end

  describe '.undeploy' do
    it 'fails when the service is not deployed' do
      result = described_class.undeploy(event: event, context: nil)

      expect(result[:Status]).to eq(:fail)
      expect(result[:Error].first).to match(/No production ASG of thezoo/)
    end
  end
end
