# frozen_string_literal: true

require_relative 'base'
require_relative '../cdp/target_finder'

module MCP
  module TradingView
    module Tools
      # Tab management — TradingView Desktop is an Electron app and each
      # chart window is a separate CDP page target. We list/activate via the
      # debugger HTTP API and open/close via simulated keyboard shortcuts.
      module Tab
        # Shared logic for enumerating chart tabs and applying the cosmetic
        # title cleanup the upstream MCP server did.
        module_function

        def list_tabs
          targets = CDP::TargetFinder.all_chart_targets
          tabs = targets.each_with_index.map do |t, i|
            {
              index:    i,
              id:       t['id'],
              title:    t['title'].to_s.sub(/^Live stock.*charts on /, ''),
              url:      t['url'],
              chart_id: t['url'].to_s[%r{/chart/([^/?]+)}, 1]
            }
          end
          { success: true, tab_count: tabs.size, tabs: tabs }
        end

        class List < Base
          tool_name 'tab_list'
          description 'List all open TradingView chart tabs (CDP page targets)'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            Tab.list_tabs
          end
        end

        # Cmd+T / Cmd+W are Electron app-menu shortcuts: the native menu
        # consumes them before the renderer sees the event, so CDP synthetic
        # key dispatch is silently ignored. We shell out to osascript so the
        # keystroke goes through the OS input pipeline — the same channel a
        # real keyboard press would hit.
        TAB_MOD_KEY = RUBY_PLATFORM.match?(/darwin/) ? :cmd : :ctrl

        class New < Base
          tool_name 'tab_new'
          description 'Open a new TradingView chart tab via Cmd/Ctrl+T (OS-level keystroke).'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            session.os_keystroke(key: 't', modifiers: [TAB_MOD_KEY])
            sleep 2.0 # TV needs time to materialise the new page target
            { success: true, action: 'new_tab_opened' }.merge(Tab.list_tabs)
          end
        end

        class Close < Base
          tool_name 'tab_close'
          description 'Close the currently focused TradingView chart tab via Cmd/Ctrl+W (OS-level keystroke).'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            before = Tab.list_tabs
            raise 'Cannot close the last tab. Use tv_launch to restart TradingView instead.' if before[:tab_count] <= 1

            session.os_keystroke(key: 'w', modifiers: [TAB_MOD_KEY])
            sleep 1.0
            after = Tab.list_tabs
            {
              success:     true,
              action:      'tab_closed',
              tabs_before: before[:tab_count],
              tabs_after:  after[:tab_count]
            }
          end
        end

        class Switch < Base
          tool_name 'tab_switch'
          description 'Switch focus to a TradingView chart tab by zero-based index from tab_list'
          input_schema({
            type: 'object',
            properties: { index: { type: 'integer', minimum: 0, description: 'Zero-based tab index' } },
            required: ['index'],
            additionalProperties: false
          })

          def self.perform(index:)
            tabs   = Tab.list_tabs
            count  = tabs[:tab_count]
            target = tabs[:tabs][index] || raise("Tab index #{index} out of range (have #{count} tabs)")

            CDP::TargetFinder.activate(target[:id])
            { success: true, action: 'switched', index: index, tab_id: target[:id], chart_id: target[:chart_id] }
          end
        end
      end
    end
  end
end
