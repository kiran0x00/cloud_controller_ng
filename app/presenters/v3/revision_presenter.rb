require 'presenters/v3/base_presenter'
require 'presenters/mixins/metadata_presentation_helpers'

module VCAP::CloudController
  module Presenters
    module V3
      class RevisionPresenter < BasePresenter
        include VCAP::CloudController::Presenters::Mixins::MetadataPresentationHelpers

        def to_hash
          {
            guid: revision.guid,
            version: revision.version,
            droplet: {
              guid: revision.droplet_guid,
            },
            processes: processes,
            sidecars: sidecars,
            description: revision.description,
            relationships: {
              app: {
                data: {
                  guid: revision.app_guid,
                },
              },
            },
            created_at: revision.created_at,
            updated_at: revision.updated_at,
            links: build_links,
            metadata: {
              labels: hashified_labels(revision.labels),
              annotations: hashified_annotations(revision.annotations),
            }
          }
        end

        private

        def revision
          @resource
        end

        def build_links
          url_builder = VCAP::CloudController::Presenters::ApiUrlBuilder.new

          {
            self: {
              href: url_builder.build_url(path: "/v3/revisions/#{revision.guid}")
            },
            app: {
              href: url_builder.build_url(path: "/v3/apps/#{revision.app_guid}")
            },
            environment_variables: {
              href: url_builder.build_url(path: "/v3/revisions/#{revision.guid}/environment_variables")
            }
          }
        end

        def processes
          revision.commands_by_process_type.map { |k, v| [k, { 'command' => v }] }.to_h
        end

        def sidecars
          revision.sidecars.map do |sidecar|
            {
              name: sidecar.name,
              command: sidecar.command,
              memory_in_mb: sidecar.memory,
              process_types: sidecar.revision_sidecar_process_types.map(&:type),
            }
          end
        end
      end
    end
  end
end
