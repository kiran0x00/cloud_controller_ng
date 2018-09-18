require 'spec_helper'
require 'cloud_controller/deployment_updater/dispatcher'

module VCAP::CloudController
  RSpec.describe DeploymentUpdater::Dispatcher do
    let(:a_day_ago) { Time.now - 1.day }
    let(:an_hour_ago) { Time.now - 1.hour }
    let(:web_process) { ProcessModel.make(instances: 2, created_at: a_day_ago) }
    let!(:route_mapping) { RouteMappingModel.make(app: web_process.app, process_type: web_process.type) }
    let(:deploying_web_process) { ProcessModel.make(app: web_process.app, type: 'web-deployment-guid-1', instances: 5) }
    let(:original_web_process_instance_count) { 6 }

    let!(:deployment) do
      DeploymentModel.make(
        app: web_process.app,
        deploying_web_process: deploying_web_process,
        state: 'DEPLOYING',
        original_web_process_instance_count: original_web_process_instance_count
      )
    end

    let(:deployer) { DeploymentUpdater::Dispatcher }
    let(:diego_instances_reporter) { instance_double(Diego::InstancesReporter) }
    let(:all_instances_results) {
      {
        0 => { state: 'RUNNING', uptime: 50, since: 2 },
        1 => { state: 'RUNNING', uptime: 50, since: 2 },
        2 => { state: 'RUNNING', uptime: 50, since: 2 },
      }
    }
    let(:instances_reporters) { double(:instance_reporters) }
    let(:logger) { instance_double(Steno::Logger, info: nil, error: nil) }
    let(:workpool) { instance_double(WorkPool, submit: nil, drain: nil) }

    describe '.update' do
      before do
        allow(CloudController::DependencyLocator.instance).to receive(:instances_reporters).and_return(instances_reporters)
        allow(instances_reporters).to receive(:all_instances_for_app).and_return(all_instances_results)
        allow(WorkPool).to receive(:new).and_return(workpool)
        allow(Steno).to receive(:logger).and_return(logger)

        allow(workpool).to receive(:submit).with(deployment, logger).and_yield(deployment, logger)
      end

      context 'when all new deploying_web_processes are running' do
        context 'when a deployment is in flight' do
          it 'is locked' do
            allow(DeploymentModel).to receive(:where).and_return(instance_double(Sequel::Dataset, all: [deployment]))
            allow(deployment).to receive(:lock!).and_call_original

            deployer.dispatch

            expect(deployment).to have_received(:lock!).twice
          end

          it 'scales the web process down by one' do
            expect {
              deployer.dispatch
            }.to change {
              web_process.reload.instances
            }.by(-1)
          end

          it 'scales up the new web process by one' do
            expect {
              deployer.dispatch
            }.to change {
              deploying_web_process.reload.instances
            }.by(1)
          end
        end

        context 'when the deployment process has reached original_web_process_instance_count' do
          let!(:space) { web_process.space }

          let(:app_guid) { "I'm the real web guid" }
          let(:the_best_app) { AppModel.make(name: 'clem', guid: app_guid) }
          let!(:web_process) { ProcessModel.make(app: the_best_app, guid: app_guid, instances: 1, created_at: a_day_ago) }
          let!(:deploying_web_process) {
            ProcessModel.make(
              app: web_process.app,
              type: 'web-deployment-guid-1',
              instances: original_web_process_instance_count,
              guid: "I'm just a webish guid"
            )
          }

          let!(:interim_deploying_web_process) {
            ProcessModel.make(
              app: web_process.app,
              created_at: an_hour_ago,
              type: 'web-deployment-guid-interim',
              instances: 1,
              guid: 'interim-guid'
            )
          }

          let!(:interim_route_mapping) { RouteMappingModel.make(app: web_process.app, process_type: interim_deploying_web_process.type) }

          let!(:non_web_process1) { ProcessModel.make(app: the_best_app, instances: 2, type: 'worker') }
          let!(:non_web_process2) { ProcessModel.make(app: the_best_app, instances: 2, type: 'clock') }

          let!(:route1) { Route.make(space: space, host: 'hostname1') }
          let!(:route_mapping1) { RouteMappingModel.make(app: web_process.app, route: route1, process_type: web_process.type) }
          let!(:route2) { Route.make(space: space, host: 'hostname2') }
          let!(:route_mapping2) { RouteMappingModel.make(app: deploying_web_process.app, route: route2, process_type: deploying_web_process.type) }

          before do
            allow(ProcessRestart).to receive(:restart)
          end

          it 'replaces the existing web process with the deploying_web_process' do
            deploying_web_process_guid = deploying_web_process.guid
            expect(ProcessModel.map(&:type)).to match_array(['web', 'web-deployment-guid-interim', 'web-deployment-guid-1', 'worker', 'clock'])

            deployer.dispatch

            deployment.reload
            the_best_app.reload

            after_web_process = the_best_app.web_process
            expect(after_web_process.guid).to eq(deploying_web_process_guid)
            expect(after_web_process.instances).to eq(original_web_process_instance_count)

            expect(ProcessModel.find(guid: deploying_web_process_guid)).not_to be_nil
            expect(ProcessModel.find(guid: the_best_app.guid)).to be_nil

            expect(ProcessModel.map(&:type)).to match_array(['web', 'worker', 'clock'])
          end

          it 'deletes all route mappings affiliated with the deploying process' do
            expect(RouteMappingModel.where(app: deploying_web_process.app,
                                           process_type: deploying_web_process.type)).to have(1).items

            deployer.dispatch

            expect(RouteMappingModel.where(app: deploying_web_process.app,
                                           process_type: deploying_web_process.type)).to have(0).items
          end

          it 'cleans up any extra processes and route mappings from the deployment train' do
            deployer.dispatch
            expect(ProcessModel.find(guid: interim_deploying_web_process.guid)).to be_nil
            expect(RouteMappingModel.find(process_type: interim_deploying_web_process.type)).to be_nil
          end

          it 'puts the deployment into its finished DEPLOYED_STATE' do
            deployer.dispatch
            deployment.reload

            expect(deployment.state).to eq(DeploymentModel::DEPLOYED_STATE)
          end

          it 'restarts the non-web processes, but not the web process' do
            deployer.dispatch
            deployment.reload

            expect(ProcessRestart).
              to have_received(:restart).
              with(process: non_web_process1, config: TestConfig.config_instance, stop_in_runtime: true)

            expect(ProcessRestart).
              to have_received(:restart).
              with(process: non_web_process2, config: TestConfig.config_instance, stop_in_runtime: true)

            expect(ProcessRestart).
              not_to have_received(:restart).
              with(process: web_process, config: TestConfig.config_instance, stop_in_runtime: true)

            expect(ProcessRestart).
              not_to have_received(:restart).
              with(process: deploying_web_process, config: TestConfig.config_instance, stop_in_runtime: true)

            expect(deployment.state).to eq(DeploymentModel::DEPLOYED_STATE)
          end

          it 'drains the workpool' do
            deployer.dispatch

            expect(workpool).to have_received(:drain)
          end
        end

        context 'when the (oldest) web process will be at zero instances' do
          let(:web_process) { ProcessModel.make(instances: 1, created_at: a_day_ago, type: 'web') }

          it 'destroys the oldest webish process' do
            deployer.dispatch
            expect(ProcessModel.all.map(&:guid)).not_to include(web_process.guid)
          end

          it 'does not destroy any route mappings' do
            expect do
              deployer.dispatch
            end.not_to change {
              RouteMappingModel.count
            }
          end
        end

        context 'when the oldest webish process will be at zero instances and is not web' do
          let(:oldest_webish_process) do
            ProcessModel.make(
              instances: 1,
              app: web_process.app,
              created_at: a_day_ago - 10,
              type: 'web-deployment-middle-train-car'
            )
          end

          let!(:oldest_route_mapping) do
            RouteMappingModel.make(app: oldest_webish_process.app, process_type: oldest_webish_process.type)
          end

          it 'destroys the oldest webish process' do
            deployer.dispatch
            expect(ProcessModel.all.map(&:guid)).not_to include(oldest_webish_process.guid)
          end

          it 'destroys the old webish route mapping' do
            deployer.dispatch
            expect(RouteMappingModel.where(app: web_process.app).map(&:process_type)).not_to include(oldest_webish_process.type)
          end
        end
      end

      context 'when the deployment is in state DEPLOYED' do
        let(:finished_web_process) { ProcessModel.make(instances: 0, created_at: a_day_ago) }
        let(:finished_deploying_web_process_guid) { ProcessModel.make(instances: 2) }
        let!(:finished_deployment) { DeploymentModel.make(app: finished_web_process.app, deploying_web_process: finished_deploying_web_process_guid, state: 'DEPLOYED') }

        before do
          allow(workpool).to receive(:submit).with(finished_deployment, logger).and_yield(finished_deployment, logger)
        end

        it 'does not scale the deployment' do
          expect {
            deployer.dispatch
          }.not_to change {
            finished_web_process.reload.instances
          }

          expect {
            deployer.dispatch
          }.not_to change {
            finished_deploying_web_process_guid.reload.instances
          }
        end
      end

      context 'when one of the deploying_web_process instances is starting' do
        let(:all_instances_results) {
          {
            0 => { state: 'RUNNING', uptime: 50, since: 2 },
            1 => { state: 'STARTING', uptime: 50, since: 2 },
            2 => { state: 'STARTING', uptime: 50, since: 2 },
          }
        }

        it 'does not scales the process' do
          expect {
            deployer.dispatch
          }.not_to change {
            web_process.reload.instances
          }

          expect {
            deployer.dispatch
          }.not_to change {
            deploying_web_process.reload.instances
          }
        end
      end

      context 'when one of the deploying_web_process instances is failing' do
        let(:all_instances_results) {
          {
            0 => { state: 'RUNNING', uptime: 50, since: 2 },
            1 => { state: 'FAILING', uptime: 50, since: 2 },
            2 => { state: 'FAILING', uptime: 50, since: 2 },
          }
        }

        it 'does not scale the process' do
          expect {
            deployer.dispatch
          }.not_to change {
            web_process.reload.instances
          }

          expect {
            deployer.dispatch
          }.not_to change {
            deploying_web_process.reload.instances
          }
        end
      end

      context 'when Diego is unavailable while checking instance status' do
        before do
          allow(instances_reporters).to receive(:all_instances_for_app).and_raise(CloudController::Errors::ApiError.new_from_details('InstancesUnavailable', 'omg it broke'))
        end

        it 'does not scale the process' do
          expect {
            deployer.dispatch
          }.not_to change {
            web_process.reload.instances
          }

          expect {
            deployer.dispatch
          }.not_to change {
            deploying_web_process.reload.instances
          }
        end
      end

      context 'when an error occurs while scaling a deployment' do
        let(:failing_process) { ProcessModel.make(app: web_process.app, type: 'failing', instances: 5) }
        let!(:failing_deployment) { DeploymentModel.make(app: web_process.app, deploying_web_process: failing_process, state: 'DEPLOYING') }

        before do
          allow(workpool).to receive(:submit).with(failing_deployment, logger).and_yield(failing_deployment, logger)
          allow(failing_deployment).to receive(:app).and_raise(StandardError.new('Something real bad happened'))
        end

        it 'logs the error' do
          expect {
            deployer.dispatch
          }.not_to change {
            failing_process.reload.instances
          }

          expect(logger).to have_received(:error).with(
            'error-scaling-deployment',
            deployment_guid: failing_deployment.guid,
            error: 'StandardError',
            error_message: 'Something real bad happened',
            backtrace: anything
          )
        end

        it 'is able to scale the other deployments' do
          expect {
            deployer.dispatch
          }.to change {
            deploying_web_process.reload.instances
          }.by(1)
        end

        it 'still drains the workpool' do
          deployer.dispatch

          expect(workpool).to have_received(:drain)
        end
      end

      context 'when the deployment is in state CANCELING' do
        let(:canceling_web_process_instances_count) { 2 }
        let(:canceling_deploying_web_process_instances_count) { 3 }
        let(:canceling_web_process) do
          ProcessModel.make(instances: canceling_web_process_instances_count, type: 'web')
        end
        let(:canceling_deploying_web_process) do
          ProcessModel.make(
            app: app,
            instances: canceling_deploying_web_process_instances_count,
            type: "web-deployment-#{deployment.guid}")
        end
        let(:app) { canceling_web_process.app }
        let(:deploying_droplet) { DropletModel.make(app: app, process_types: { 'web' => 'oh-no!' }) }
        let(:previous_droplet) { DropletModel.make(app: app, process_types: { 'web' => 'yee-haw!' }) }
        let!(:canceling_deployment) do
          DeploymentModel.make(
            app: app,
            droplet: deploying_droplet,
            previous_droplet: previous_droplet,
            deploying_web_process: canceling_deploying_web_process,
            original_web_process_instance_count: 6,
            state: 'CANCELING'
          )
        end

        before do
          app.update(droplet: previous_droplet)
          allow(workpool).to receive(:submit).with(canceling_deployment, logger).and_yield(canceling_deployment, logger)
        end

        it 'deletes the deploying process' do
          deployer.dispatch
          expect(ProcessModel.find(guid: canceling_deploying_web_process.guid)).to be_nil
        end

        context 'when routes are mapped' do
          let(:deploying_process_route) { Route.make(space: canceling_deploying_web_process.space) }

          before do
            RouteMappingModel.make(app: app, route: deploying_process_route,
                                   process_type: canceling_deploying_web_process.type)
          end

          it 'deletes the deploying web process and associated routes' do
            deployer.dispatch
            expect(RouteMappingModel.find(app: app, process_type: canceling_deploying_web_process.type)).to be_nil
          end

          it 'tells co-pilot the routes are unmapped', isolation: :truncation do
            TestConfig.override(copilot: { enabled: true })
            allow(Copilot::Adapter).to receive(:unmap_route)
            deployer.dispatch
            expect(Copilot::Adapter).to have_received(:unmap_route).once
          end
        end

        it 'rolls back to the correct number of instances' do
          deployer.dispatch
          expect(canceling_web_process.reload.instances).to eq(6)
          expect(canceling_deploying_web_process.exists?).to be false
          expect(canceling_web_process.droplet_checksum).to eq(canceling_deployment.previous_droplet.checksum)
        end

        it 'sets the deployment to CANCELED' do
          deployer.dispatch
          expect(canceling_deployment.state).to eq('CANCELED')
        end
      end
    end
  end
end