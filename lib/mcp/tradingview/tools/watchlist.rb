# frozen_string_literal: true

require_relative 'base'

module MCP
  module TradingView
    module Tools
      # Watchlist tools — read the right-side panel and add symbols to it.
      #
      # TradingView doesn't expose a clean JS API for this, so both ops are
      # DOM-driven: read uses data-symbol-full attrs, add types into the
      # symbol-search input that pops up when clicking the panel's "+"
      # button. Brittle to TV redesigns — selectors are best-effort with
      # multiple fallbacks.
      module Watchlist
        ENSURE_PANEL_OPEN_JS = <<~JS
          (function() {
            var btn = document.querySelector('[data-name="base-watchlist-widget-button"]')
              || document.querySelector('[aria-label*="Watchlist"]');
            if (!btn) return { error: 'Watchlist button not found' };
            var active = btn.getAttribute('aria-pressed') === 'true'
              || /Active|active/.test(btn.classList.toString());
            if (!active) { btn.click(); return { opened: true }; }
            return { opened: false };
          })()
        JS

        READ_SYMBOLS_JS = <<~JS
          (function() {
            var container = document.querySelector('[class*="layout__area--right"]');
            if (!container || container.offsetWidth < 50) return { symbols: [], source: 'panel_closed' };

            var seen = {}, results = [];

            // Preferred: explicit data attributes.
            var symbolEls = container.querySelectorAll('[data-symbol-full]');
            for (var i = 0; i < symbolEls.length; i++) {
              var sym = symbolEls[i].getAttribute('data-symbol-full');
              if (!sym || seen[sym]) continue;
              seen[sym] = true;
              var row = symbolEls[i].closest('[class*="row"]') || symbolEls[i].parentElement;
              var nums = [];
              if (row) {
                var cells = row.querySelectorAll('[class*="cell"], [class*="column"]');
                for (var j = 0; j < cells.length; j++) {
                  var t = cells[j].textContent.trim();
                  if (t && /^[\\-+]?[\\d,]+\\.?\\d*%?$/.test(t.replace(/[\\s,]/g, ''))) nums.push(t);
                }
              }
              results.push({ symbol: sym, last: nums[0] || null, change: nums[1] || null, change_percent: nums[2] || null });
            }
            if (results.length > 0) return { symbols: results, source: 'data_attributes' };

            // Fallback: scrape ticker-shaped text in the panel.
            var items = container.querySelectorAll('[class*="symbolName"], [class*="tickerName"], [class*="symbol-"]');
            for (var k = 0; k < items.length; k++) {
              var text = items[k].textContent.trim();
              if (text && /^[A-Z][A-Z0-9.:!]{0,20}$/.test(text) && !seen[text]) {
                seen[text] = true;
                results.push({ symbol: text, last: null, change: null, change_percent: null });
              }
            }
            return { symbols: results, source: results.length > 0 ? 'text_scan' : 'empty' };
          })()
        JS

        CLICK_ADD_BUTTON_JS = <<~JS
          (function() {
            var selectors = [
              '[data-name="add-symbol-button"]',
              '[aria-label="Add symbol"]',
              '[aria-label*="Add symbol"]',
              'button[class*="addSymbol"]'
            ];
            for (var s = 0; s < selectors.length; s++) {
              var btn = document.querySelector(selectors[s]);
              if (btn && btn.offsetParent !== null) { btn.click(); return { found: true, selector: selectors[s] }; }
            }
            var container = document.querySelector('[class*="layout__area--right"]');
            if (container) {
              var buttons = container.querySelectorAll('button');
              for (var i = 0; i < buttons.length; i++) {
                var ariaLabel = buttons[i].getAttribute('aria-label') || '';
                if (/add.*symbol/i.test(ariaLabel) || buttons[i].textContent.trim() === '+') {
                  buttons[i].click();
                  return { found: true, method: 'fallback' };
                }
              }
            }
            return { found: false };
          })()
        JS

        class Get < Base
          tool_name 'watchlist_get'
          description 'Read the symbols visible in the active TradingView watchlist panel.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            data    = session.evaluate(READ_SYMBOLS_JS) || {}
            symbols = data['symbols'] || []
            { success: true, count: symbols.size, source: data['source'] || 'unknown', symbols: symbols }
          end
        end

        # Two symbols are considered equivalent for matching purposes if
        # they're identical OR share the same bare ticker after dropping
        # the EXCHANGE: prefix. So "AAPL" matches "NASDAQ:AAPL", which is
        # what users mean when they list bare tickers in rules.json but TV
        # has stored fully-qualified ones.
        def self.same_symbol?(a, b)
          a = a.to_s.upcase
          b = b.to_s.upcase
          return true if a == b

          a.split(':').last == b.split(':').last
        end

        REMOVE_BY_SYMBOL_JS_TEMPLATE = <<~JS
          (function() {
            var target = %<target>s.toLowerCase();
            var els = document.querySelectorAll('[data-symbol-full]');
            for (var i = 0; i < els.length; i++) {
              var sym = (els[i].getAttribute('data-symbol-full') || '').toLowerCase();
              var bareSym = sym.split(':').pop();
              var bareTarget = target.split(':').pop();
              if (sym === target || bareSym === bareTarget) {
                var row = els[i].closest('[class*="row"]') || els[i].parentElement;
                if (!row) return { found: true, removed: false, error: 'no row container' };
                // Selector list ordered most-specific to most-generic. Note
                // `[class*="removeButton"]` (no tag prefix) — TV's current
                // build renders the X as a <span>, not a <button>.
                var delBtn = row.querySelector('[data-name="remove-symbol-button"]')
                          || row.querySelector('[class*="removeButton"]')
                          || row.querySelector('[aria-label*="Remove"]')
                          || row.querySelector('button[class*="remove"]')
                          || row.querySelector('button[class*="delete"]')
                          || row.querySelector('[class*="closeButton"]');
                if (!delBtn) return { found: true, removed: false, error: 'delete control not located' };
                delBtn.click();
                return { found: true, removed: true, matched_symbol: sym };
              }
            }
            return { found: false, removed: false };
          })()
        JS

        # JS path that fires the chart's "Add to watchlist" action. This is
        # the same code TV runs when a user picks "Add to watchlist" from the
        # chart's right-click menu — it goes through TV's internal
        # initWatchlistWidget(t => t.addSymbols([sym])) call, no UI involved.
        # Discovered by inspecting addToWatchlist._execute() on the live page.
        SILENT_ADD_CURRENT_CHART_JS = <<~JS
          (function() {
            var w = window.TradingViewApi
              && window.TradingViewApi._chartWidgetCollection
              && window.TradingViewApi._chartWidgetCollection._subscribedChartWidget;
            if (!w) return { error: 'No subscribed chart widget — is a chart loaded?' };
            var action = w._actions && w._actions.addToWatchlist;
            if (!action || typeof action._execute !== 'function') {
              return { error: 'addToWatchlist action not available on this TV build' };
            }
            try {
              action._execute();
              var sym = action._chart && action._chart.model && action._chart.model();
              return { success: true, fired: true };
            } catch (e) {
              return { error: 'addToWatchlist._execute threw: ' + (e && e.message || e) };
            }
          })()
        JS

        # Add the chart's CURRENT symbol to the watchlist silently (no popup,
        # no dialog). Pair this with chart_set_symbol — set the chart to the
        # symbol you want, then call this. That's exactly what /run does in
        # its chart-tab loop.
        class AddCurrentChartSymbol < Base
          tool_name 'watchlist_add_current_chart_symbol'
          description 'Silently add the active chart\'s current symbol to the watchlist (no popup). Use after chart_set_symbol to seed the watchlist as you iterate symbols.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            result = session.evaluate(SILENT_ADD_CURRENT_CHART_JS) || {}
            raise result['error'] if result['error']

            { success: true, action: 'silent_add_current_chart_symbol' }
          end
        end

        class Add < Base
          tool_name 'watchlist_add'
          description 'Add a symbol to the active TradingView watchlist via the "+" search dialog. Prefer watchlist_add_current_chart_symbol — that is silent. This UI-based tool is the fallback when the chart cannot be set to the desired symbol first.'
          input_schema({
            type: 'object',
            properties: {
              symbol: { type: 'string', description: 'Symbol to add — exchange-prefixed values (NASDAQ:AAPL) match more reliably than bare tickers' }
            },
            required: ['symbol'],
            additionalProperties: false
          })

          def self.perform(symbol:)
            Watchlist.ensure_panel_open!
            Watchlist.click_add_button!

            session.insert_text(symbol)
            sleep 0.6

            session.dispatch_keystroke(key: 'Enter',  code: 'Enter',  virtual_key: 13)
            sleep 0.3
            # Send Escape twice — once to close any "no exact match" tooltip,
            # once to close the dropdown if Enter didn't auto-dismiss it.
            session.dispatch_keystroke(key: 'Escape', code: 'Escape', virtual_key: 27)
            session.dispatch_keystroke(key: 'Escape', code: 'Escape', virtual_key: 27)

            { success: true, symbol: symbol, action: 'added' }
          end
        end

        class Remove < Base
          tool_name 'watchlist_remove'
          description 'Remove a symbol from the watchlist by clicking the row\'s hover-X button. Matches "AAPL" to "NASDAQ:AAPL" and vice-versa.'
          input_schema({
            type: 'object',
            properties: { symbol: { type: 'string' } },
            required: ['symbol'],
            additionalProperties: false
          })

          def self.perform(symbol:)
            Watchlist.ensure_panel_open!
            target_js = JSON.generate(symbol)
            result    = session.evaluate(format(REMOVE_BY_SYMBOL_JS_TEMPLATE, target: target_js)) || {}

            unless result['found']
              return { success: true, symbol: symbol, action: 'not_present' }
            end
            raise result['error'] if !result['removed'] && result['error']

            { success: true, symbol: symbol, matched_symbol: result['matched_symbol'], action: 'removed' }
          end
        end

        class Set < Base
          tool_name 'watchlist_set'
          description 'Make the watchlist exactly equal to the given list of symbols. Symbols already present (matched case-insensitively, prefix-tolerantly) are left alone — only diffs cause UI activity.'
          input_schema({
            type: 'object',
            properties: {
              symbols: { type: 'array', items: { type: 'string' }, description: 'Desired final watchlist contents' },
              prune:   { type: 'boolean', description: 'Remove watchlist entries not in `symbols`. Default: true.' }
            },
            required: ['symbols'],
            additionalProperties: false
          })

          # Idempotent — running twice should report 0 changes the second
          # time (assuming no concurrent edits).
          def self.perform(symbols:, prune: true)
            desired   = Array(symbols).map(&:to_s).reject(&:empty?)
            current   = current_symbols
            to_add    = desired.reject { |d| current.any? { |c| Watchlist.same_symbol?(d, c) } }
            to_remove = prune ? current.reject { |c| desired.any? { |d| Watchlist.same_symbol?(c, d) } } : []

            removed_log = to_remove.map { |s| safe_call(s) { Remove.perform(symbol: s) } }
            added_log   = to_add.map    { |s| safe_call(s) { Add.perform(symbol: s) } }

            {
              success:        true,
              kept_count:     current.size - removed_log.count { |r| r[:action] == 'removed' },
              added_count:    added_log.count   { |r| r[:action] == 'added'   },
              removed_count:  removed_log.count { |r| r[:action] == 'removed' },
              skipped_adds:   added_log.select  { |r| r[:error] }.map { |r| { symbol: r[:symbol], error: r[:error] } },
              skipped_removes: removed_log.select { |r| r[:error] }.map { |r| { symbol: r[:symbol], error: r[:error] } }
            }
          end

          # Wraps a sub-tool call so a single per-symbol failure doesn't
          # abort the whole set operation. The returned hash always includes
          # `:symbol` even on failure so the caller can attribute errors.
          def self.safe_call(symbol)
            response = yield
            response.is_a?(Hash) ? response.transform_keys(&:to_sym) : { symbol: symbol, error: response.to_s }
          rescue StandardError => e
            { symbol: symbol, error: e.message }
          end

          def self.current_symbols
            data = session.evaluate(READ_SYMBOLS_JS) || {}
            (data['symbols'] || []).map { |row| row['symbol'].to_s }.reject(&:empty?)
          end

          private_class_method :safe_call, :current_symbols
        end

        # JS that locates the user's `###BOT` section in the active custom
        # list, slices the symbols inside it, and reports whether BOT is the
        # last section (matters for silent adds — _execute always appends to
        # the very end of the list, so it only lands inside BOT if BOT is
        # the last marker).
        #
        # Resilient to TV redesigns that change the watchlist DOM: it walks
        # the React fiber from any draggable element to find the customLists
        # Redux store rather than relying on `data-symbol-full` selectors.
        BOT_SECTION_PROBE_JS = <<~JS
          (function() {
            // Re-acquire the watchlist Redux store; the panel may not be open
            // yet so we accept any draggable as a fiber anchor.
            if (!window.__TVMCP_WATCHLIST_STORE__ ||
                typeof window.__TVMCP_WATCHLIST_STORE__.getState !== 'function') {
              var anchor = document.querySelector('[data-symbol-full]')
                        || document.querySelector('[draggable="true"]');
              if (!anchor) return { error: 'Watchlist panel not rendered. Open the right-side panel first.' };
              var fk = Object.keys(anchor).find(function(k) { return k.startsWith('__reactFiber$'); });
              if (!fk) return { error: 'No React fiber on watchlist anchor.' };
              var node = anchor[fk];
              while (node && (!node.memoizedProps || !node.memoizedProps.store ||
                !Object.keys(node.memoizedProps.store.getState() || {}).includes('customLists'))) {
                node = node.return;
              }
              if (!node) return { error: 'customLists Redux store not found in fiber.' };
              window.__TVMCP_WATCHLIST_STORE__ = node.memoizedProps.store;
            }

            var s = window.__TVMCP_WATCHLIST_STORE__;
            var lists = s.getState().customLists.lists;
            // The active user-custom list is the first id (the second is
            // 'deleted_symbols_list_id' which TV uses internally for undo).
            var listId = lists.ids.find(function(id) { return id !== 'deleted_symbols_list_id'; });
            if (!listId) return { error: 'No active custom list.' };
            var symbols = lists.byId[listId].symbols;

            // ###BOT match — case-insensitive, tolerant of zero-width
            // separators TV inserts to mark "collapsed" sections.
            var botIdx = -1;
            for (var i = 0; i < symbols.length; i++) {
              var clean = symbols[i].replace(/[\\u200B-\\u200F\\u2060-\\u206F]/g, '');
              if (/^###BOT$/i.test(clean)) { botIdx = i; break; }
            }
            if (botIdx === -1) return { error: 'No ###BOT section marker found. Create one in TradingView first.' };

            var endIdx = symbols.length;
            for (var j = botIdx + 1; j < symbols.length; j++) {
              if (symbols[j].startsWith('###')) { endIdx = j; break; }
            }
            return {
              listId: listId,
              botIdx: botIdx,
              endIdx: endIdx,
              botIsLast: endIdx === symbols.length,
              inSection: symbols.slice(botIdx + 1, endIdx)
            };
          })()
        JS

        # Make the contents of the user's `###BOT` watchlist section equal
        # to the supplied symbols. Idempotent — symbols already in the
        # section are skipped (no UI activity), missing ones are added via
        # the silent _execute path, extras are removed via the row's
        # remove-button.
        #
        # Requires the user to have created a `###BOT` section in their
        # watchlist AND for it to be the LAST section (since silent adds
        # always append to the very end of the list — they only land inside
        # BOT when no section follows it).
        class SyncBotSection < Base
          tool_name 'watchlist_sync_bot_section'
          description "Sync the active watchlist's ###BOT section to exactly the given symbols. Silent — no popups. Requires ###BOT section to exist and to be the LAST section in the watchlist."
          input_schema({
            type: 'object',
            properties: {
              symbols: { type: 'array', items: { type: 'string' }, description: 'Desired final symbols inside the ###BOT section' }
            },
            required: ['symbols'],
            additionalProperties: false
          })

          def self.perform(symbols:)
            probe = session.evaluate(BOT_SECTION_PROBE_JS) || {}
            raise probe['error'] if probe['error']

            desired    = Array(symbols).map(&:to_s).reject(&:empty?)
            in_section = Array(probe['inSection'])
            to_add     = desired.reject    { |d| in_section.any? { |c| Watchlist.same_symbol?(d, c) } }
            to_remove  = in_section.reject { |c| desired.any?    { |d| Watchlist.same_symbol?(c, d) } }

            removed = to_remove.map { |s| safe_step(s) { Remove.perform(symbol: s) } }
            added   = to_add.map    { |s| safe_step(s) { silent_add(s) } }

            warning = nil
            warning = '###BOT is not the last section — new symbols may land outside it. Move ###BOT to the bottom of your sections in TradingView.' if !probe['botIsLast'] && !to_add.empty?

            {
              success:       true,
              kept_count:    in_section.size - removed.count { |r| r[:action] == 'removed' },
              added_count:   added.count    { |r| r[:action] == 'added' },
              removed_count: removed.count  { |r| r[:action] == 'removed' },
              warning:       warning,
              errors: (added + removed).select { |r| r[:error] }.map { |r| { symbol: r[:symbol], error: r[:error] } }
            }.compact
          end

          # Sets the chart to `symbol`, fires the silent `addToWatchlist`
          # action. Returns a hash matching the Add/Remove tool shape so
          # the caller can dedupe across all sub-results.
          def self.silent_add(symbol)
            sym_js = JSON.generate(symbol)
            session.evaluate_async(<<~JS)
              (async function() {
                var chart = window.TradingViewApi._activeChartWidgetWV.value();
                chart.setSymbol(#{sym_js}, {});
                await new Promise(function(r) { setTimeout(r, 1200); });
                var w = window.TradingViewApi._chartWidgetCollection
                  && window.TradingViewApi._chartWidgetCollection._subscribedChartWidget;
                var a = w && w._actions && w._actions.addToWatchlist;
                if (a && a._execute) a._execute();
                await new Promise(function(r) { setTimeout(r, 800); });
                return 'ok';
              })()
            JS
            { symbol: symbol, action: 'added' }
          end

          def self.safe_step(symbol)
            response = yield
            response.is_a?(Hash) ? response.transform_keys(&:to_sym) : { symbol: symbol, error: response.to_s }
          rescue StandardError => e
            { symbol: symbol, error: e.message }
          end

          private_class_method :silent_add, :safe_step
        end

        module_function

        def ensure_panel_open!
          state = session.evaluate(ENSURE_PANEL_OPEN_JS) || {}
          raise state['error'] if state['error']

          sleep 0.5 if state['opened']
        end

        def click_add_button!
          result = session.evaluate(CLICK_ADD_BUTTON_JS) || {}
          raise 'Add-symbol button not found in watchlist panel' unless result['found']

          sleep 0.4
        end

        # Local helper so module-level helpers can talk to the singleton
        # the same way Tools::Base does.
        def session
          Session.current
        end
      end
    end
  end
end
