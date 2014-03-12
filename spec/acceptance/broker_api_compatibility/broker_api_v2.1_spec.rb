require 'spec_helper'

describe 'Service Broker API integration' do
  describe 'v2.1' do

    before(:all) { setup_cc }
    after(:all) { $spec_env.reset_database_with_seeds }

    describe 'Binding' do
      let(:space_guid) { @space_guid }
      let(:app_guid) { @app_guid }
      let(:service_instance_guid) { @service_instance_guid }

      before do
        setup_broker
        provision_service
        create_app
      end

      after do
        delete_broker
      end

      describe 'service binding request' do
        before do
          stub_request(:put, %r(/v2/service_instances/#{service_instance_guid}/service_bindings/.*$)).
            to_return(status: 200, body: '{}')

          post('/v2/service_bindings',
            { app_guid: app_guid, service_instance_guid: service_instance_guid }.to_json,
            json_headers(admin_headers))
        end

        it 'sends the app_guid as part of the request' do
          a_request(:put, %r(broker-url/v2/service_instances/#{service_instance_guid}/service_bindings/.*$)).
            with(body: hash_including(app_guid: app_guid)).
            should have_been_made
        end
      end
    end
  end
end
