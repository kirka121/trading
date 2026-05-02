# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module MCP
  module TradingView
    module CDP
      # Discovers Chrome DevTools Protocol page targets exposed by TradingView
      # Desktop (an Electron app launched with --remote-debugging-port=9222).
      #
      # The Electron parent process runs an HTTP introspection server at the
      # debugging port. `GET /json/list` returns one entry per page-like
      # target. We pick the chart page; everything else (login windows,
      # service workers) is ignored.
      module TargetFinder
        DEFAULT_HOST = 'localhost'
        DEFAULT_PORT = 9222
        # rubocop:disable Style/RegexpLiteral
        CHART_URL    = %r{tradingview\.com/chart}i
        ANY_TV_URL   = /tradingview/i
        # rubocop:enable Style/RegexpLiteral

        class NotFound < StandardError; end

        module_function

        # Returns an array of all CDP page targets the debugger reports.
        # Used by tools that enumerate tabs (tab_list).
        def all_chart_targets(host: DEFAULT_HOST, port: DEFAULT_PORT)
          fetch_targets(host: host, port: port).select do |t|
            t['type'] == 'page' && CHART_URL.match?(t['url'].to_s)
          end
        end

        # Picks the best chart target — prefers /chart pages, then any
        # TradingView page. Raises NotFound if nothing matches.
        def find(host: DEFAULT_HOST, port: DEFAULT_PORT)
          targets = fetch_targets(host: host, port: port)
          chart   = targets.find { |t| t['type'] == 'page' && CHART_URL.match?(t['url'].to_s) }
          chart ||= targets.find { |t| t['type'] == 'page' && ANY_TV_URL.match?(t['url'].to_s) }
          chart || raise(NotFound, "No TradingView chart target on #{host}:#{port}. Is TradingView open with a chart?")
        end

        # Bring a tab to the foreground. CDP exposes /json/activate/<id> for this.
        def activate(target_id, host: DEFAULT_HOST, port: DEFAULT_PORT)
          uri = URI("http://#{host}:#{port}/json/activate/#{target_id}")
          Net::HTTP.get_response(uri)
        end

        def fetch_targets(host:, port:)
          uri = URI("http://#{host}:#{port}/json/list")
          response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |http|
            http.get(uri.request_uri)
          end
          raise NotFound, "CDP /json/list returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, EOFError => e
          raise NotFound, "Cannot reach Chrome DevTools at #{host}:#{port} — #{e.class}: #{e.message}. Is TradingView running with --remote-debugging-port?"
        end
      end
    end
  end
end
