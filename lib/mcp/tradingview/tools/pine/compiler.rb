# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module MCP
  module TradingView
    module Tools
      module Pine
        # Calls TradingView's public Pine compile-light endpoint to validate
      # a Pine source against the real compiler — no auth needed. Used by
      # `pine_check` so the user gets server-grade error feedback without
      # having to inject the source into the editor and click anything.
      module Compiler
        ENDPOINT = URI('https://pine-facade.tradingview.com/pine-facade/translate_light?user_name=Guest&pine_id=00000000-0000-0000-0000-000000000000')

        module_function

        def check(source)
          response = post_form(ENDPOINT, 'source' => source)
          raise "TradingView pine-facade returned #{response.code}: #{response.message}" unless response.is_a?(Net::HTTPSuccess)

          parsed   = JSON.parse(response.body)
          inner    = parsed['result'] || {}
          errors   = Array(inner['errors2']).map   { |e| diag(e) }
          warnings = Array(inner['warnings2']).map { |w| diag(w, error: false) }
          errors << { message: parsed['error'] } if parsed['error'].is_a?(String)

          {
            success:       true,
            compiled:      errors.empty?,
            error_count:   errors.size,
            warning_count: warnings.size,
            errors:        errors.empty? ? nil : errors,
            warnings:      warnings.empty? ? nil : warnings,
            note:          errors.empty? ? 'Pine Script compiled successfully.' : nil
          }.compact
        end

        def diag(entry, error: true)
          {
            line:       entry.dig('start', 'line'),
            column:     entry.dig('start', 'column'),
            end_line:   error ? entry.dig('end', 'line') : nil,
            end_column: error ? entry.dig('end', 'column') : nil,
            message:    entry['message']
          }.compact
        end

        def post_form(uri, fields)
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
            request = Net::HTTP::Post.new(uri.request_uri)
            request['Accept']  = 'application/json'
            request['Referer'] = 'https://www.tradingview.com/'
            request.set_form_data(fields)
            http.request(request)
          end
        end
      end
      end
    end
  end
end
