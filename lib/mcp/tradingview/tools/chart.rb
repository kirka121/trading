# frozen_string_literal: true

require 'json'
require_relative 'base'
require_relative '../known_paths'
require_relative '../chart_ready_waiter'

module MCP
  module TradingView
    module Tools
      # Chart-control tools: read state, change symbol/timeframe/type, and
      # add/remove indicators. Every JS expression is interpolated against
      # KnownPaths::CHART_API; user-supplied strings are escaped via
      # `js_string` to make injection structural rather than a footgun.
      module Chart
        CHART_API = KnownPaths::CHART_API

        TYPE_MAP = {
          'Bars' => 0, 'Candles' => 1, 'Line' => 2, 'Area' => 3,
          'Renko' => 4, 'Kagi' => 5, 'PointAndFigure' => 6, 'LineBreak' => 7,
          'HeikinAshi' => 8, 'HollowCandles' => 9
        }.freeze

        class GetState < Base
          tool_name 'chart_get_state'
          description 'Get current chart state (symbol, timeframe, chart type, indicators with entity IDs)'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          STATE_JS = <<~JS
            (function() {
              var chart = #{CHART_API};
              var studies = [];
              try {
                studies = chart.getAllStudies().map(function(s) {
                  return { id: s.id, name: s.name || s.title || 'unknown' };
                });
              } catch (e) {}
              return {
                symbol: chart.symbol(),
                resolution: chart.resolution(),
                chartType: chart.chartType(),
                studies: studies
              };
            })()
          JS

          def self.perform(**_)
            { success: true }.merge(session.evaluate(STATE_JS))
          end
        end

        class SetSymbol < Base
          tool_name 'chart_set_symbol'
          description 'Change the chart symbol (e.g., BTCUSD, AAPL, NYMEX:CL1!)'
          input_schema({
            type: 'object',
            properties: { symbol: { type: 'string', description: 'TradingView symbol' } },
            required: ['symbol'],
            additionalProperties: false
          })

          def self.perform(symbol:)
            sym = js_string(symbol)
            session.evaluate_async(<<~JS)
              (function() {
                var chart = #{CHART_API};
                return new Promise(function(resolve) {
                  chart.setSymbol(#{sym}, {});
                  setTimeout(resolve, 500);
                });
              })()
            JS
            ready = ChartReadyWaiter.wait(session, expected_symbol: symbol)
            { success: true, symbol: symbol, chart_ready: ready }
          end
        end

        class SetTimeframe < Base
          tool_name 'chart_set_timeframe'
          description 'Change the chart timeframe / resolution (e.g., 1, 5, 15, 60, D, W, M)'
          input_schema({
            type: 'object',
            properties: { timeframe: { type: 'string', description: 'TradingView resolution string' } },
            required: ['timeframe'],
            additionalProperties: false
          })

          def self.perform(timeframe:)
            tf = js_string(timeframe)
            session.evaluate("#{CHART_API}.setResolution(#{tf}, {})")
            ready = ChartReadyWaiter.wait(session)
            { success: true, timeframe: timeframe, chart_ready: ready }
          end
        end

        class SetType < Base
          tool_name 'chart_set_type'
          description 'Change the chart type. Pass a name (Bars/Candles/Line/Area/Renko/Kagi/PointAndFigure/LineBreak/HeikinAshi/HollowCandles) or a number 0-9.'
          input_schema({
            type: 'object',
            properties: { chart_type: { type: 'string', description: 'Type name or numeric string 0-9' } },
            required: ['chart_type'],
            additionalProperties: false
          })

          def self.perform(chart_type:)
            num = TYPE_MAP[chart_type.to_s] || Integer(chart_type.to_s)
            session.evaluate("#{CHART_API}.setChartType(#{num})")
            { success: true, chart_type: chart_type, type_num: num }
          rescue ArgumentError, TypeError
            raise "Unknown chart type: #{chart_type}. Use a name (Candles, Line, ...) or number 0-9."
          end
        end

        class ManageIndicator < Base
          tool_name 'chart_manage_indicator'
          description 'Add or remove an indicator on the chart. Use full names like "Relative Strength Index" — short names like "RSI" will not match.'
          input_schema({
            type: 'object',
            properties: {
              action:    { type: 'string', enum: %w[add remove] },
              indicator: { type: 'string', description: 'Full TradingView study name' },
              entity_id: { type: 'string', description: 'Required for remove; obtain from chart_get_state' },
              inputs:    { type: 'string', description: 'JSON-encoded input overrides, e.g. {"length":20}' }
            },
            required: %w[action indicator],
            additionalProperties: false
          })

          def self.perform(action:, indicator:, entity_id: nil, inputs: nil)
            case action
            when 'add'    then add_indicator(indicator: indicator, inputs: inputs)
            when 'remove' then remove_indicator(indicator: indicator, entity_id: entity_id)
            else raise 'action must be "add" or "remove"'
            end
          end

          def self.add_indicator(indicator:, inputs:)
            input_pairs = parse_inputs(inputs).map { |k, v| { id: k, value: v } }
            ids_js = "#{CHART_API}.getAllStudies().map(function(s){return s.id;})"
            before = Array(session.evaluate(ids_js))
            session.evaluate(<<~JS)
              (function() {
                #{CHART_API}.createStudy(#{js_string(indicator)}, false, false, #{JSON.generate(input_pairs)});
              })()
            JS
            sleep 1.5
            after = Array(session.evaluate(ids_js))
            new_ids = after - before
            {
              success:        !new_ids.empty?,
              action:         'add',
              indicator:      indicator,
              entity_id:      new_ids.first,
              new_study_count: new_ids.size
            }
          end

          def self.remove_indicator(indicator:, entity_id:)
            raise 'entity_id required for remove action. Use chart_get_state to find study IDs.' unless entity_id

            session.evaluate("#{CHART_API}.removeEntity(#{js_string(entity_id)})")
            { success: true, action: 'remove', indicator: indicator, entity_id: entity_id }
          end

          def self.parse_inputs(raw)
            return {} if raw.nil? || raw == ''
            return raw if raw.is_a?(Hash)

            JSON.parse(raw)
          rescue JSON::ParserError => e
            raise "inputs must be a JSON object string (got: #{e.message})"
          end
          private_class_method :add_indicator, :remove_indicator, :parse_inputs
        end
      end
    end
  end
end
