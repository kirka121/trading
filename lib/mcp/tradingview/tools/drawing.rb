# frozen_string_literal: true

require 'json'
require_relative 'base'
require_relative '../known_paths'

module MCP
  module TradingView
    module Tools
      # Drawings (lines, rectangles, text, etc.) are reached via the chart
      # widget's createShape / createMultipointShape entry points. We let
      # callers pass overrides as a JSON string for a stable wire format.
      module Drawing
        CHART_API = KnownPaths::CHART_API

        # Resolves to a chart-API expression once we know it exists. Each
        # tool calls this so a TV update breaking the API surfaces fast and
        # specifically.
        def self.api(session) = KnownPaths.verify(session, CHART_API, 'Chart API')
        private_class_method :api

        class Shape < Base
          tool_name 'draw_shape'
          description 'Draw a shape on the chart. Common shapes: horizontal_line, trend_line, rectangle, text. Provide point2 for multi-point shapes.'
          input_schema({
            type: 'object',
            properties: {
              shape:     { type: 'string', description: 'Shape type, e.g. horizontal_line, trend_line, rectangle, text' },
              point:     {
                type: 'object', required: %w[time price],
                properties: { time: { type: 'number' }, price: { type: 'number' } }
              },
              point2: {
                type: 'object',
                properties: { time: { type: 'number' }, price: { type: 'number' } }
              },
              overrides: { type: 'string', description: 'JSON-encoded override map' },
              text:      { type: 'string' }
            },
            required: %w[shape point],
            additionalProperties: false
          })

          def self.perform(shape:, point:, point2: nil, overrides: nil, text: nil)
            api          = Drawing.send(:api, session)
            override_map = overrides.nil? || overrides.empty? ? {} : JSON.parse(overrides)
            override_str = JSON.generate(override_map)
            text_str     = text.nil? ? '""' : js_string(text)
            shape_str    = js_string(shape)

            ids_js = "#{api}.getAllShapes().map(function(s){return s.id;})"
            before = Array(session.evaluate(ids_js))

            if point2
              session.evaluate(<<~JS)
                #{api}.createMultipointShape(
                  [{ time: #{Float(point[:time])}, price: #{Float(point[:price])} },
                   { time: #{Float(point2[:time])}, price: #{Float(point2[:price])} }],
                  { shape: #{shape_str}, overrides: #{override_str}, text: #{text_str} }
                )
              JS
            else
              session.evaluate(<<~JS)
                #{api}.createShape(
                  { time: #{Float(point[:time])}, price: #{Float(point[:price])} },
                  { shape: #{shape_str}, overrides: #{override_str}, text: #{text_str} }
                )
              JS
            end

            sleep 0.2
            after  = Array(session.evaluate(ids_js))
            new_id = (after - before).first
            { success: true, shape: shape, entity_id: new_id }
          end
        end

        class List < Base
          tool_name 'draw_list'
          description 'List all drawings on the active chart with their entity IDs and names.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            api    = Drawing.send(:api, session)
            shapes = session.evaluate(<<~JS)
              (function() {
                return #{api}.getAllShapes().map(function(s) { return { id: s.id, name: s.name }; });
              })()
            JS
            { success: true, count: shapes.size, shapes: shapes }
          end
        end

        class GetProperties < Base
          tool_name 'draw_get_properties'
          description 'Inspect a drawing — points, override properties, and visibility flags. Use draw_list to find an entity_id.'
          input_schema({
            type: 'object',
            properties: { entity_id: { type: 'string' } },
            required: ['entity_id'],
            additionalProperties: false
          })

          def self.perform(entity_id:)
            api = Drawing.send(:api, session)
            eid = js_string(entity_id)
            result = session.evaluate(<<~JS)
              (function() {
                var api = #{api};
                var eid = #{eid};
                var shape = api.getShapeById(eid);
                if (!shape) return { error: 'Shape not found: ' + eid };
                var props = { entity_id: eid };
                try { props.points = shape.getPoints(); } catch (e) { props.points_error = e.message; }
                try { props.properties = shape.getProperties ? shape.getProperties() : shape.properties(); }
                catch (e) { props.properties_error = e.message; }
                try { props.visible = shape.isVisible(); } catch (e) {}
                try { props.locked = shape.isLocked(); } catch (e) {}
                try { props.selectable = shape.isSelectionEnabled(); } catch (e) {}
                try {
                  var all = api.getAllShapes();
                  for (var i = 0; i < all.length; i++) { if (all[i].id === eid) { props.name = all[i].name; break; } }
                } catch (e) {}
                return props;
              })()
            JS

            raise result['error'] if result.is_a?(Hash) && result['error']

            { success: true }.merge(result)
          end
        end

        class RemoveOne < Base
          tool_name 'draw_remove_one'
          description 'Remove a single drawing by entity_id (from draw_list).'
          input_schema({
            type: 'object',
            properties: { entity_id: { type: 'string' } },
            required: ['entity_id'],
            additionalProperties: false
          })

          def self.perform(entity_id:)
            api    = Drawing.send(:api, session)
            eid    = js_string(entity_id)
            result = session.evaluate(<<~JS)
              (function() {
                var api = #{api};
                var eid = #{eid};
                var before = api.getAllShapes();
                var found = false;
                for (var i = 0; i < before.length; i++) { if (before[i].id === eid) { found = true; break; } }
                if (!found) return { removed: false, error: 'Shape not found: ' + eid };
                api.removeEntity(eid);
                var after = api.getAllShapes();
                var still = false;
                for (var j = 0; j < after.length; j++) { if (after[j].id === eid) { still = true; break; } }
                return { removed: !still, entity_id: eid, remaining_shapes: after.length };
              })()
            JS

            raise result['error'] if result['error']

            {
              success:          true,
              entity_id:        result['entity_id'],
              removed:          result['removed'],
              remaining_shapes: result['remaining_shapes']
            }
          end
        end

        class Clear < Base
          tool_name 'draw_clear'
          description 'Remove every drawing from the active chart.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            api = Drawing.send(:api, session)
            session.evaluate("#{api}.removeAllShapes()")
            { success: true, action: 'all_shapes_removed' }
          end
        end
      end
    end
  end
end
