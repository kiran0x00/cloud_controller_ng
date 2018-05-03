require 'spec_helper'
require 'presenters/v3/paginated_list_presenter'

module VCAP::CloudController::Presenters::V3
  RSpec.describe PaginatedListPresenter do
    subject(:presenter) { PaginatedListPresenter.new(presenter: MonkeyPresenter, dataset: dataset, path: path, message: message) }
    let(:set) { [Monkey.new('bobo'), Monkey.new('george')] }
    let(:dataset) { double('sequel dataset') }
    let(:message) { double('message', pagination_options: pagination_options, to_param_hash: {}) }
    let(:pagination_options) { double('pagination', per_page: 50, page: 1, order_by: 'monkeys', order_direction: 'asc') }
    let(:paginator) { instance_double(VCAP::CloudController::SequelPaginator) }
    let(:paginated_result) { VCAP::CloudController::PaginatedResult.new(set, 2, pagination_options) }

    before do
      allow(VCAP::CloudController::SequelPaginator).to receive(:new).and_return(paginator)
      allow(paginator).to receive(:get_page).with(dataset, pagination_options).and_return(paginated_result)
    end

    class Monkey
      attr_reader :name

      def initialize(name)
        @name = name
      end
    end

    class MonkeyPresenter < BasePresenter
      def to_hash
        {
          name: @resource.name,
        }
      end
    end

    describe '#to_hash' do
      let(:path) { '/some/path' }

      it 'returns a paginated response for the set, with path only used in pagination' do
        expect(presenter.to_hash).to eq({
          pagination: {
            total_results: 2,
            total_pages: 1,
            first: { href: "#{link_prefix}/some/path?order_by=%2Bmonkeys&page=1&per_page=50" },
            last: { href: "#{link_prefix}/some/path?order_by=%2Bmonkeys&page=1&per_page=50" },
            next: nil,
            previous: nil
          },
          resources: [
            { name: 'bobo' },
            { name: 'george' },
          ]
        })
      end

      it 'sends false for show_secrets' do
        allow(MonkeyPresenter).to receive(:new).and_call_original
        presenter.to_hash
        expect(MonkeyPresenter).to have_received(:new).
          with(anything, show_secrets: false, censored_message: BasePresenter::REDACTED_LIST_MESSAGE).exactly(set.count).times
      end

      context 'when show_secrets is true' do
        subject(:presenter) do
          PaginatedListPresenter.new(presenter: MonkeyPresenter, dataset: dataset, path: path, message: message, show_secrets: true)
        end

        it 'sends true for show_secrets' do
          allow(MonkeyPresenter).to receive(:new).and_call_original
          presenter.to_hash
          expect(MonkeyPresenter).to have_received(:new).
            with(anything, show_secrets: true, censored_message: BasePresenter::REDACTED_LIST_MESSAGE).exactly(set.count).times
        end
      end

      context 'when there are decorators' do
        let(:banana_decorator) do
          Class.new do
            class << self
              def decorate(hash, monkeys)
                hash[:included] ||= {}
                hash[:included][:bananas] = monkeys.map { |monkey| "#{monkey.name}'s banana" }
                hash
              end
            end
          end
        end

        let(:tail_decorator) do
          Class.new do
            class << self
              def decorate(hash, monkeys)
                hash[:included] ||= {}
                hash[:included][:tails] = monkeys.map { |monkey| "#{monkey.name}'s tail" }
                hash
              end
            end
          end
        end

        subject(:presenter) do
          PaginatedListPresenter.new(
            presenter: MonkeyPresenter,
            dataset: dataset,
            path: path,
            message: message,
            show_secrets: true,
            decorators: [banana_decorator, tail_decorator]
          )
        end

        it 'decorates the hash with them' do
          result = presenter.to_hash
          expect(result[:included][:bananas]).to match_array(["bobo's banana", "george's banana"])
          expect(result[:included][:tails]).to match_array(["bobo's tail", "george's tail"])
        end
      end
    end

    describe '#present_pagination_hash' do
      let(:page) { 1 }
      let(:per_page) { 1 }
      let(:total_results) { 2 }
      let(:total_pages) { 2 }
      let(:options) { { page: page, per_page: per_page } }
      let(:pagination_options) { VCAP::CloudController::PaginationOptions.new(options) }
      let(:paginated_result) { VCAP::CloudController::PaginatedResult.new(double(:results), total_results, pagination_options) }
      let(:path) { '/v3/cloudfoundry/is-great' }

      it 'includes total_results' do
        result = presenter.present_pagination_hash(paginated_result, path)

        tr = result[:total_results]
        expect(tr).to eq(total_results)
      end

      it 'includes total_pages' do
        result = presenter.present_pagination_hash(paginated_result, path)

        tr = result[:total_pages]
        expect(tr).to eq(total_pages)
      end

      it 'includes first_url' do
        result = presenter.present_pagination_hash(paginated_result, path)

        first_url = result[:first][:href]
        expect(first_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=1&per_page=#{per_page}")
      end

      it 'includes last_url' do
        result = presenter.present_pagination_hash(paginated_result, path)

        last_url = result[:last][:href]
        expect(last_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=2&per_page=#{per_page}")
      end

      it 'sets first and last page to 1 if there is 1 page' do
        paginated_result = VCAP::CloudController::PaginatedResult.new([], 0, pagination_options)
        result = presenter.present_pagination_hash(paginated_result, path)

        last_url  = result[:last][:href]
        first_url = result[:first][:href]
        expect(last_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=1&per_page=#{per_page}")
        expect(first_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=1&per_page=#{per_page}")
      end

      it 'includes the filters in the result urls' do
        filters = double('filters', to_param_hash: { facet1: 'value1' })
        paginated_result = VCAP::CloudController::PaginatedResult.new([], 0, pagination_options)
        result = presenter.present_pagination_hash(paginated_result, path, filters)

        first_url = result[:first][:href]
        expect(first_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?facet1=value1&page=1&per_page=#{per_page}")
      end

      context 'when on the first page' do
        let(:page) { 1 }

        it 'sets previous_url to nil' do
          result = presenter.present_pagination_hash(paginated_result, path)

          previous_url = result[:previous]
          expect(previous_url).to be_nil
        end
      end

      context 'when NOT on the first page' do
        let(:page) { 2 }

        it 'includes previous_url' do
          result = presenter.present_pagination_hash(paginated_result, path)

          previous_url = result[:previous][:href]
          expect(previous_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=1&per_page=#{per_page}")
        end
      end

      context 'when on the last page' do
        let(:page) { total_results / per_page }
        let(:per_page) { 1 }

        it 'sets next_url to nil' do
          result = presenter.present_pagination_hash(paginated_result, path)

          next_url = result[:next]
          expect(next_url).to be_nil
        end
      end

      context 'when NOT on the last page' do
        let(:page) { 1 }
        let(:per_page) { 1 }

        it 'includes next_url' do
          result = presenter.present_pagination_hash(paginated_result, path)

          next_url = result[:next][:href]
          expect(next_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=2&per_page=#{per_page}")
        end
      end

      context 'pagination options' do
        let(:page) { 2 }
        let(:total_results) { 3 }
        let(:order_by) { 'id' }
        let(:order_direction) { 'asc' }
        let(:options) { { page: page, per_page: per_page, order_by: order_by, order_direction: order_direction } }

        it 'does not set order information if both order options are default' do
          result = presenter.present_pagination_hash(paginated_result, path)

          first_url = result[:first][:href]
          expect(first_url).to eq("#{link_prefix}/v3/cloudfoundry/is-great?page=1&per_page=#{per_page}")
        end

        context 'when order_by has been queried, it includes order_direction prefix' do
          let(:order_by) { 'created_at' }

          it 'sets the pagination options' do
            result = presenter.present_pagination_hash(paginated_result, path)

            first_page    = result[:first][:href]
            last_page     = result[:last][:href]
            next_page     = result[:next][:href]
            previous_page = result[:previous][:href]

            expect(first_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=%2B#{order_by}&page=1&per_page=#{per_page}")
            expect(last_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=%2B#{order_by}&page=3&per_page=#{per_page}")
            expect(next_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=%2B#{order_by}&page=3&per_page=#{per_page}")
            expect(previous_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=%2B#{order_by}&page=1&per_page=#{per_page}")
          end

          context 'when the order direction is desc' do
            let(:order_direction) { 'desc' }

            it 'sets the pagination options' do
              result = presenter.present_pagination_hash(paginated_result, path)

              first_page    = result[:first][:href]
              last_page     = result[:last][:href]
              next_page     = result[:next][:href]
              previous_page = result[:previous][:href]

              expect(first_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=-#{order_by}&page=1&per_page=#{per_page}")
              expect(last_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=-#{order_by}&page=3&per_page=#{per_page}")
              expect(next_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=-#{order_by}&page=3&per_page=#{per_page}")
              expect(previous_page).to eq("#{link_prefix}/v3/cloudfoundry/is-great?order_by=-#{order_by}&page=1&per_page=#{per_page}")
            end
          end
        end
      end
    end
  end
end