# frozen_string_literal: true

# Every AWS client the code under test builds is a stub (the clients are constructed
# inside src/, so Aws.config is the seam). Params are still validated against the real
# API models. Override ssm_params / dynamo_item per example.
RSpec.shared_context 'with stubbed aws' do
  let(:slug) { 'dev-account' }
  let(:service) { 'thezoo' }
  let(:prefix) { '/teak/dev' }
  let(:account_info) { { prefix: prefix, name: 'Dev', environment: 'development' } }
  let(:dynamo_calls) { [] }
  let(:dynamo_item) { { 'id' => "#{slug}.#{service}" } }
  let(:ssm_params) do
    {
      "/omat/account_registry/#{slug}" => JSON.generate(account_info)
    }
  end

  before do
    Deployomat::CredentialCache.instance_variable_set(:@meta_role_credentials, nil)
    Deployomat::CredentialCache.instance_variable_set(:@role_credentials, nil)

    Aws.config.update(
      stub_responses: true,
      ssm: {
        stub_responses: {
          get_parameter: lambda do |ctx|
            value = ssm_params[ctx.params[:name]]
            next 'ParameterNotFound' if value.nil?

            { parameter: { name: ctx.params[:name], type: 'String', value: value } }
          end
        }
      },
      dynamodb: {
        stub_responses: {
          get_item: ->(_ctx) { { item: dynamo_item } },
          update_item: lambda do |ctx|
            dynamo_calls << ctx.params
            { attributes: dynamo_item }
          end
        }
      }
    )
  end
end
