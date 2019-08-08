require 'presenters/v3/paginated_list_presenter'
require 'presenters/v3/space_presenter'
require 'messages/space_create_message'
require 'messages/space_delete_unmapped_routes_message'
require 'messages/space_update_message'
require 'messages/space_update_isolation_segment_message'
require 'messages/spaces_list_message'
require 'messages/space_show_message'
require 'actions/space_update_isolation_segment'
require 'actions/space_create'
require 'actions/space_update'
require 'actions/space_delete_unmapped_routes'
require 'fetchers/space_list_fetcher'
require 'fetchers/space_fetcher'
require 'jobs/v3/space_delete_unmapped_routes_job'

class SpacesV3Controller < ApplicationController
  def index
    message = SpacesListMessage.from_params(query_params)
    invalid_param!(message.errors.full_messages) unless message.valid?

    decorators = []
    decorators << IncludeOrganizationDecorator if message.include&.include?('org')

    render status: :ok, json: Presenters::V3::PaginatedListPresenter.new(
      presenter: Presenters::V3::SpacePresenter,
      paginated_result: SequelPaginator.new.get_page(readable_spaces(message: message), message.try(:pagination_options)),
      path: '/v3/spaces',
      message: message,
      decorators: decorators
    )
  end

  def show
    space = SpaceFetcher.new.fetch(hashed_params[:guid])
    message = SpaceShowMessage.from_params(query_params)

    space_not_found! unless space && permission_queryer.can_read_from_space?(space.guid, space.organization.guid)
    invalid_param!(message.errors.full_messages) unless message.valid?

    decorators = []
    decorators << IncludeOrganizationDecorator if message.include&.include?('org')

    render status: :ok, json: Presenters::V3::SpacePresenter.new(space, decorators: decorators)
  end

  def create
    message = SpaceCreateMessage.new(hashed_params[:body])
    missing_org = 'Invalid organization. Ensure the organization exists and you have access to it.'

    unprocessable!(message.errors.full_messages) unless message.valid?
    unprocessable!(missing_org) unless permission_queryer.can_read_from_org?(message.organization_guid)
    unauthorized! unless permission_queryer.can_write_to_org?(message.organization_guid)

    org = fetch_organization(message.organization_guid)
    unprocessable!(missing_org) unless org
    space = SpaceCreate.new(perm_client: perm_client, user_audit_info: user_audit_info).create(org, message)

    render status: 201, json: Presenters::V3::SpacePresenter.new(space)
  rescue SpaceCreate::Error => e
    unprocessable!(e.message)
  end

  def update
    space = fetch_space(hashed_params[:guid])
    space_not_found! unless space
    org = space.organization

    message = VCAP::CloudController::SpaceUpdateMessage.new(hashed_params[:body])
    unprocessable!(message.errors.full_messages) unless message.valid?
    unauthorized! unless roles.admin? || org.managers.include?(current_user) || space.managers.include?(current_user)

    space = SpaceUpdate.new.update(space, message)

    render status: :ok, json: Presenters::V3::SpacePresenter.new(space)
  end

  def destroy
    space = fetch_space(hashed_params[:guid])
    space_not_found! unless space && permission_queryer.can_read_from_space?(space.guid, space.organization.guid)
    unauthorized! unless permission_queryer.can_write_to_org?(space.organization.guid)

    service_event_repository = VCAP::CloudController::Repositories::ServiceEventRepository.new(user_audit_info)
    delete_action = SpaceDelete.new(user_audit_info, service_event_repository)
    deletion_job = VCAP::CloudController::Jobs::DeleteActionJob.new(Space, space.guid, delete_action)
    pollable_job = Jobs::Enqueuer.new(deletion_job, queue: 'cc-generic').enqueue_pollable

    url_builder = VCAP::CloudController::Presenters::ApiUrlBuilder.new
    head :accepted, 'Location' => url_builder.build_url(path: "/v3/jobs/#{pollable_job.guid}")
  end

  def delete_unmapped_routes
    message = SpaceDeleteUnmappedRoutesMessage.new(query_params)
    unprocessable!(message.errors.full_messages) unless message.valid?

    space = fetch_space(hashed_params[:guid])
    space_not_found! unless space && permission_queryer.can_read_from_space?(space.guid, space.organization.guid)

    unauthorized! unless permission_queryer.can_write_to_space?(space.guid)

    deletion_job = VCAP::CloudController::Jobs::V3::SpaceDeleteUnmappedRoutesJob.new(space)
    pollable_job = Jobs::Enqueuer.new(deletion_job, queue: 'cc-generic').enqueue_pollable

    url_builder = VCAP::CloudController::Presenters::ApiUrlBuilder.new
    head :accepted, 'Location' => url_builder.build_url(path: "/v3/jobs/#{pollable_job.guid}")
  end

  def update_isolation_segment
    space = fetch_space(hashed_params[:guid])
    space_not_found! unless space
    org = space.organization
    org_not_found! unless org
    space_not_found! unless permission_queryer.can_read_from_space?(space.guid, org.guid)
    unauthorized! unless roles.admin? || space.organization.managers.include?(current_user)

    message = SpaceUpdateIsolationSegmentMessage.new(hashed_params[:body])
    unprocessable!(message.errors.full_messages) unless message.valid?

    SpaceUpdateIsolationSegment.new(user_audit_info).update(space, org, message)

    isolation_segment = fetch_isolation_segment(message.isolation_segment_guid)
    render status: :ok, json: Presenters::V3::ToOneRelationshipPresenter.new(
      resource_path: "spaces/#{space.guid}",
      related_instance: isolation_segment,
      relationship_name: 'isolation_segment',
      related_resource_name: 'isolation_segments'
    )
  rescue SpaceUpdateIsolationSegment::Error => e
    unprocessable!(e.message)
  end

  def show_isolation_segment
    space = fetch_space(hashed_params[:guid])
    space_not_found! unless space

    org = space.organization
    space_not_found! unless permission_queryer.can_read_from_space?(space.guid, org.guid)

    isolation_segment = fetch_isolation_segment(space.isolation_segment_guid)
    render status: :ok, json: Presenters::V3::ToOneRelationshipPresenter.new(
      resource_path: "spaces/#{space.guid}",
      related_instance: isolation_segment,
      relationship_name: 'isolation_segment',
      related_resource_name: 'isolation_segments'
    )
  end

  private

  def fetch_organization(guid)
    Organization.where(guid: guid).first
  end

  def fetch_space(guid)
    Space.where(guid: guid).first
  end

  def fetch_isolation_segment(guid)
    IsolationSegmentModel.where(guid: guid).first
  end

  def space_not_found!
    resource_not_found!(:space)
  end

  def org_not_found!
    resource_not_found!(:org)
  end

  def readable_spaces(message:)
    if permission_queryer.can_read_globally?
      if message.requested?(:guids)
        SpaceListFetcher.new.fetch(message: message, guids: message.guids, eager_loaded_associations: Presenters::V3::SpacePresenter.associated_resources)
      else
        SpaceListFetcher.new.fetch_all(message: message, eager_loaded_associations: Presenters::V3::SpacePresenter.associated_resources)
      end
    else
      readable_space_guids = permission_queryer.readable_space_guids
      filtered_readable_guids = message.requested?(:guids) ? readable_space_guids & message.guids : readable_space_guids
      SpaceListFetcher.new.fetch(message: message, guids: filtered_readable_guids, eager_loaded_associations: Presenters::V3::SpacePresenter.associated_resources)
    end
  end
end
