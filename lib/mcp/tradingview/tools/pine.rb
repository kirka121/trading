# frozen_string_literal: true

require 'json'
require_relative 'base'
require_relative 'pine/monaco_editor'
require_relative 'pine/analyzer'
require_relative 'pine/compiler'

module MCP
  module TradingView
    module Tools
      # Pine Script tools — read/write source in Monaco, compile via the
      # public pine-facade API, click through TV's compile/save UI.
      #
      # The DOM-poking tools (compile, save, smart_compile, get_console)
      # are inherently brittle to TV redesigns. They share a small set of
      # fallbacks (button selectors → keyboard shortcuts) so single-class
      # renames don't take down the whole module.
      module Pine
        # Pulls the source out of Monaco (no editor → raise so callers see why).
        def self.read_source(session)
          source = session.evaluate(MonacoEditor.with_editor('return m.editor.getValue();'))
          raise 'Monaco editor found but getValue() returned null.' if source.nil?

          source
        end
        private_class_method :read_source

        def self.write_source(session, source)
          ok = session.evaluate(
            MonacoEditor.with_editor("m.editor.setValue(#{Base.send(:js_string, source)}); return true;", fallback: 'false')
          )
          raise 'Monaco found but setValue() failed.' unless ok
        end
        private_class_method :write_source

        def self.ensure_open!(session)
          raise 'Could not open Pine Editor or Monaco not found in React fiber tree.' unless MonacoEditor.ensure_open(session)
        end
        private_class_method :ensure_open!

        # ── Pure tools (no CDP) ───────────────────────────────────────────

        class Analyze < Base
          tool_name 'pine_analyze'
          description 'Run a fast, offline static-analysis pass over a Pine Script source string.'
          input_schema({
            type: 'object',
            properties: { source: { type: 'string' } },
            required: ['source'],
            additionalProperties: false
          })

          def self.perform(source:)
            Analyzer.analyze(source)
          end
        end

        class Check < Base
          tool_name 'pine_check'
          description "Compile-check a Pine source string via TradingView's public pine-facade API. Returns errors/warnings without touching the editor."
          input_schema({
            type: 'object',
            properties: { source: { type: 'string' } },
            required: ['source'],
            additionalProperties: false
          })

          def self.perform(source:)
            Compiler.check(source)
          end
        end

        # ── Editor tools (need a live TradingView page) ───────────────────

        class GetSource < Base
          tool_name 'pine_get_source'
          description 'Read the current Pine Editor source. WARNING: complex scripts can be 200KB+; avoid unless editing.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            Pine.send(:ensure_open!, session)
            source = Pine.send(:read_source, session)
            {
              success:    true,
              source:     source,
              line_count: source.count("\n") + 1,
              char_count: source.length
            }
          end
        end

        class SetSource < Base
          tool_name 'pine_set_source'
          description 'Replace the Pine Editor source with the provided string. Pair with pine_smart_compile to apply.'
          input_schema({
            type: 'object',
            properties: { source: { type: 'string' } },
            required: ['source'],
            additionalProperties: false
          })

          def self.perform(source:)
            Pine.send(:ensure_open!, session)
            Pine.send(:write_source, session, source)
            { success: true, lines_set: source.count("\n") + 1 }
          end
        end

        class GetErrors < Base
          tool_name 'pine_get_errors'
          description 'Read the Monaco markers (errors/warnings) for the current Pine Editor buffer.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          MARKERS_JS = MonacoEditor.with_editor(<<~JS, fallback: '[]')
            var model = m.editor.getModel();
            if (!model) return [];
            return m.env.editor.getModelMarkers({ resource: model.uri }).map(function(mk) {
              return { line: mk.startLineNumber, column: mk.startColumn, message: mk.message, severity: mk.severity };
            });
          JS

          def self.perform(**_)
            Pine.send(:ensure_open!, session)
            errors = Array(session.evaluate(MARKERS_JS))
            { success: true, has_errors: !errors.empty?, error_count: errors.size, errors: errors }
          end
        end

        class New < Base
          tool_name 'pine_new'
          description 'Replace the Pine Editor source with a starter template (indicator/strategy/library).'
          input_schema({
            type: 'object',
            properties: { type: { type: 'string', enum: %w[indicator strategy library] } },
            required: ['type'],
            additionalProperties: false
          })

          TEMPLATES = {
            'indicator' => "//@version=6\nindicator(\"My script\")\nplot(close)\n",
            'strategy'  => "//@version=6\nstrategy(\"My strategy\", overlay=true)\n",
            'library'   => "//@version=6\n// @description TODO: add library description here\nlibrary(\"MyLibrary\")\n"
          }.freeze

          def self.perform(type:)
            template = TEMPLATES[type] || raise("type must be one of: #{TEMPLATES.keys.join(', ')}")
            Pine.send(:ensure_open!, session)
            Pine.send(:write_source, session, template)
            { success: true, type: type, action: 'new_script_created' }
          end
        end

        class ListScripts < Base
          tool_name 'pine_list_scripts'
          description "List the user's saved Pine scripts (server-side via pine-facade)."
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          LIST_JS = <<~JS
            fetch('https://pine-facade.tradingview.com/pine-facade/list/?filter=saved', { credentials: 'include' })
              .then(function(r) { return r.json(); })
              .then(function(data) {
                if (!Array.isArray(data)) return { scripts: [], error: 'Unexpected response from pine-facade' };
                return {
                  scripts: data.map(function(s) {
                    return {
                      id:       s.scriptIdPart || null,
                      name:     s.scriptName || s.scriptTitle || 'Untitled',
                      title:    s.scriptTitle || null,
                      version:  s.version || null,
                      modified: s.modified || null
                    };
                  })
                };
              })
              .catch(function(e) { return { scripts: [], error: e.message }; })
          JS

          def self.perform(**_)
            data    = session.evaluate_async(LIST_JS) || {}
            scripts = data['scripts'] || []
            { success: true, scripts: scripts, count: scripts.size, source: 'internal_api', error: data['error'] }.compact
          end
        end

        class OpenScript < Base
          tool_name 'pine_open'
          description 'Open one of the saved Pine scripts (case-insensitive name match) into the editor.'
          input_schema({
            type: 'object',
            properties: { name: { type: 'string' } },
            required: ['name'],
            additionalProperties: false
          })

          def self.perform(name:)
            Pine.send(:ensure_open!, session)
            target = Base.send(:js_string, name.downcase)
            find_js = MonacoEditor::FIND_JS

            result = session.evaluate_async(<<~JS)
              (function() {
                var target = #{target};
                return fetch('https://pine-facade.tradingview.com/pine-facade/list/?filter=saved', { credentials: 'include' })
                  .then(function(r) { return r.json(); })
                  .then(function(scripts) {
                    if (!Array.isArray(scripts)) return { error: 'pine-facade returned unexpected data' };
                    var match = null;
                    for (var i = 0; i < scripts.length; i++) {
                      var sn = (scripts[i].scriptName || '').toLowerCase();
                      var st = (scripts[i].scriptTitle || '').toLowerCase();
                      if (sn === target || st === target) { match = scripts[i]; break; }
                    }
                    if (!match) {
                      for (var j = 0; j < scripts.length; j++) {
                        var sn2 = (scripts[j].scriptName || '').toLowerCase();
                        var st2 = (scripts[j].scriptTitle || '').toLowerCase();
                        if (sn2.indexOf(target) !== -1 || st2.indexOf(target) !== -1) { match = scripts[j]; break; }
                      }
                    }
                    if (!match) return { error: 'Script "' + target + '" not found. Use pine_list_scripts to see available scripts.' };
                    var id = match.scriptIdPart;
                    var ver = match.version || 1;
                    return fetch('https://pine-facade.tradingview.com/pine-facade/get/' + id + '/' + ver, { credentials: 'include' })
                      .then(function(r2) { return r2.json(); })
                      .then(function(data) {
                        var source = data.source || '';
                        if (!source) return { error: 'Script source is empty', name: match.scriptName || match.scriptTitle };
                        var m = #{find_js};
                        if (!m) return { error: 'Monaco editor not found to inject source', name: match.scriptName || match.scriptTitle };
                        m.editor.setValue(source);
                        return { success: true, name: match.scriptName || match.scriptTitle, id: id, lines: source.split('\\n').length };
                      });
                  })
                  .catch(function(e) { return { error: e.message }; });
              })()
            JS

            raise result['error'] if result.is_a?(Hash) && result['error']

            { success: true, name: result['name'], script_id: result['id'], lines: result['lines'], source: 'internal_api', opened: true }
          end
        end

        # The compile/save/smart_compile flows poke at TradingView's actual
        # toolbar buttons. Selectors are best-effort — keep them in one
        # JS expression so we can iterate on TV redesigns by editing one
        # heredoc.
        BUTTON_CLICK_JS = <<~JS
          (function() {
            var btns = document.querySelectorAll('button');
            var fallback = null, saveBtn = null;
            for (var i = 0; i < btns.length; i++) {
              var text = btns[i].textContent.trim();
              if (/save and add to chart/i.test(text)) { btns[i].click(); return 'Save and add to chart'; }
              if (!fallback && /^(Add to chart|Update on chart)/i.test(text)) fallback = btns[i];
              if (!saveBtn && btns[i].className.indexOf('saveButton') !== -1 && btns[i].offsetParent !== null) saveBtn = btns[i];
            }
            if (fallback) { fallback.click(); return fallback.textContent.trim(); }
            if (saveBtn)  { saveBtn.click();  return 'Pine Save'; }
            return null;
          })()
        JS

        class Compile < Base
          tool_name 'pine_compile'
          description 'Compile the current Pine source by clicking TradingView\'s "Save and add" / "Update on chart" button (fallback: Cmd+Enter).'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            Pine.send(:ensure_open!, session)
            clicked = session.evaluate(Pine::BUTTON_CLICK_JS)
            unless clicked
              session.dispatch_modifier_keystroke(key: 'Enter', code: 'Enter', virtual_key: 13, mod_key: :ctrl)
            end
            sleep 2.0
            { success: true, button_clicked: clicked || 'keyboard_shortcut', source: 'dom_fallback' }
          end
        end

        class Save < Base
          tool_name 'pine_save'
          description 'Save the current Pine script (Cmd+S, with a fallback to confirm any "name your script" dialog that pops up).'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          DIALOG_CONFIRM_JS = <<~JS
            (function() {
              var btns = document.querySelectorAll('button'), saveBtn = null;
              for (var i = 0; i < btns.length; i++) {
                var text = btns[i].textContent.trim();
                if (text === 'Save' && btns[i].offsetParent !== null) {
                  var parent = btns[i].closest('[class*="dialog"], [class*="modal"], [class*="popup"], [role="dialog"]');
                  if (parent) { saveBtn = btns[i]; break; }
                }
              }
              if (saveBtn) { saveBtn.click(); return true; }
              return false;
            })()
          JS

          def self.perform(**_)
            Pine.send(:ensure_open!, session)
            session.dispatch_modifier_keystroke(key: 's', code: 'KeyS', virtual_key: 83)
            sleep 0.8
            confirmed = session.evaluate(DIALOG_CONFIRM_JS)
            sleep 0.5 if confirmed
            { success: true, action: confirmed ? 'saved_with_dialog' : 'Cmd+S_dispatched' }
          end
        end

        class SmartCompile < Base
          tool_name 'pine_smart_compile'
          description 'Compile the Pine source AND report Monaco errors + whether a study was actually added to the chart.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          STUDIES_LEN_JS = <<~JS
            (function() {
              try {
                var chart = #{KnownPaths::CHART_API};
                if (chart && typeof chart.getAllStudies === 'function') return chart.getAllStudies().length;
              } catch (e) {}
              return null;
            })()
          JS

          MARKERS_JS = MonacoEditor.with_editor(<<~JS, fallback: '[]')
            var model = m.editor.getModel();
            if (!model) return [];
            return m.env.editor.getModelMarkers({ resource: model.uri }).map(function(mk) {
              return { line: mk.startLineNumber, column: mk.startColumn, message: mk.message, severity: mk.severity };
            });
          JS

          def self.perform(**_)
            Pine.send(:ensure_open!, session)
            before  = session.evaluate(STUDIES_LEN_JS)
            clicked = session.evaluate(Pine::BUTTON_CLICK_JS)
            unless clicked
              session.dispatch_modifier_keystroke(key: 'Enter', code: 'Enter', virtual_key: 13, mod_key: :ctrl)
            end
            sleep 2.5
            errors      = Array(session.evaluate(MARKERS_JS))
            after       = session.evaluate(STUDIES_LEN_JS)
            study_added = before && after ? after > before : nil

            {
              success:        true,
              button_clicked: clicked || 'keyboard_shortcut',
              has_errors:     !errors.empty?,
              errors:         errors,
              study_added:    study_added
            }
          end
        end

        class GetConsole < Base
          tool_name 'pine_get_console'
          description 'Scrape the Pine Editor console panel (errors/info/compile messages) into structured rows.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          CONSOLE_JS = <<~JS
            (function() {
              var rows = document.querySelectorAll('[class*="consoleRow"], [class*="log-"], [class*="consoleLine"]');
              if (rows.length === 0) {
                var bottom = document.querySelector('[class*="layout__area--bottom"]') ||
                             document.querySelector('[class*="bottom-widgetbar-content"]');
                if (bottom) {
                  rows = bottom.querySelectorAll('[class*="message"], [class*="log"], [class*="console"]');
                }
              }
              var results = [];
              for (var i = 0; i < rows.length; i++) {
                var text = rows[i].textContent.trim();
                if (!text) continue;
                var ts = null;
                var tsMatch = text.match(/^(\\d{4}-\\d{2}-\\d{2}\\s+)?\\d{2}:\\d{2}:\\d{2}/);
                if (tsMatch) ts = tsMatch[0];
                var type = 'info';
                var cls = rows[i].className || '';
                if (/error/i.test(cls) || /error/i.test(text.substring(0, 30))) type = 'error';
                else if (/compil/i.test(text.substring(0, 40))) type = 'compile';
                else if (/warn/i.test(cls)) type = 'warning';
                results.push({ timestamp: ts, type: type, message: text });
              }
              return results;
            })()
          JS

          def self.perform(**_)
            Pine.send(:ensure_open!, session)
            entries = Array(session.evaluate(CONSOLE_JS))
            { success: true, entries: entries, entry_count: entries.size }
          end
        end
      end
    end
  end
end
