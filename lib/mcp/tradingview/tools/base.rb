# frozen_string_literal: true

require 'json'
require 'mcp'
require_relative '../session'

module MCP
  module TradingView
    module Tools
      # Common scaffolding every TradingView MCP tool inherits.
      #
      # Subclasses define `self.perform(args)` and return a plain Hash. The
      # base wraps that hash in MCP-protocol JSON, catches StandardError,
      # and surfaces failures as { success: false, error: ... } content with
      # the protocol-level `isError` flag set so MCP clients can distinguish
      # exceptions from successful tool calls that returned an error payload.
      class Base < ::MCP::Tool
        # Most TradingView ops involve DOM/JS round-trips that take a beat —
        # we let subclasses override but a 30-second cap is rarely too tight.
        DEFAULT_TIMEOUT_S = 30

        def self.call(server_context: nil, **args)
          payload = perform(**deep_symbolize(args))
          json_response(payload, error: false)
        rescue StandardError => e
          maybe_log_error(server_context, e)
          json_response({ success: false, error: e.message }, error: true)
        end

        # Logger lookup is defensive — server_context shape isn't strictly
        # specified and we don't want a tool failure to be masked by a
        # NoMethodError from the rescue block itself.
        def self.maybe_log_error(server_context, error)
          context = server_context.respond_to?(:to_h) ? server_context.to_h : server_context
          logger  = context.is_a?(Hash) ? context[:logger] || context['logger'] : nil
          logger&.error(error.full_message)
        rescue StandardError
          # nothing to do — error logging is strictly best effort
        end
        private_class_method :maybe_log_error

        # Subclasses override. Receive keyword arguments matching their
        # input_schema and return a Hash to be JSON-serialised back to the
        # MCP client. Raise on failure — the base class catches & formats.
        def self.perform(**_args)
          raise NotImplementedError, "#{name}.perform must be implemented"
        end

        # Convenience accessor — every tool talks through the singleton.
        def self.session
          Session.current
        end

        # JSON-encode a JS string literal: handles quotes/newlines/unicode.
        def self.js_string(value)
          JSON.generate(value.to_s)
        end

        def self.json_response(hash, error:)
          ::MCP::Tool::Response.new(
            [{ type: 'text', text: JSON.generate(hash) }],
            error: error
          )
        end
        private_class_method :json_response

        def self.deep_symbolize(obj)
          case obj
          when Hash  then obj.transform_keys(&:to_sym).transform_values { |v| deep_symbolize(v) }
          when Array then obj.map { |v| deep_symbolize(v) }
          else obj
          end
        end
        private_class_method :deep_symbolize
      end
    end
  end
end
