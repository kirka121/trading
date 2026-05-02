# frozen_string_literal: true

module MCP
  module TradingView
    module Tools
      module Pine
        # Helper for talking to the Monaco editor instance embedded in
        # TradingView's Pine Editor panel.
        #
        # Monaco isn't exposed on `window` — we walk the React fiber tree
        # from the editor DOM node to find the live `IStandaloneCodeEditor`.
        # Every Pine tool calls `ensure_open` first so a panel-not-yet-
        # rendered state self-heals before we read or write source.
        module MonacoEditor
          # JS expression that returns { editor, env } or null.
          FIND_JS = <<~JS.strip
            (function findMonacoEditor() {
              var container = document.querySelector('.monaco-editor.pine-editor-monaco');
              if (!container) return null;
              var el = container, fiberKey;
              for (var i = 0; i < 20; i++) {
                if (!el) break;
                fiberKey = Object.keys(el).find(function(k) { return k.startsWith('__reactFiber$'); });
                if (fiberKey) break;
                el = el.parentElement;
              }
              if (!fiberKey) return null;
              var current = el[fiberKey];
              for (var d = 0; d < 15; d++) {
                if (!current) break;
                if (current.memoizedProps && current.memoizedProps.value && current.memoizedProps.value.monacoEnv) {
                  var env = current.memoizedProps.value.monacoEnv;
                  if (env.editor && typeof env.editor.getEditors === 'function') {
                    var editors = env.editor.getEditors();
                    if (editors.length > 0) return { editor: editors[0], env: env };
                  }
                }
                current = current.return;
              }
              return null;
            })()
          JS

          OPEN_TIMEOUT_S = 10.0
          OPEN_POLL_S    = 0.2

          module_function

          # Returns true once Monaco is reachable, false on timeout.
          def ensure_open(session)
            return true if available?(session)

            activate_panel(session)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + OPEN_TIMEOUT_S
            sleep OPEN_POLL_S until available?(session) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            available?(session)
          end

          def available?(session)
            session.evaluate("(function(){ return #{FIND_JS} !== null; })()")
          rescue StandardError
            false
          end

          def activate_panel(session)
            session.evaluate(<<~JS)
              (function() {
                var bwb = window.TradingView && window.TradingView.bottomWidgetBar;
                if (!bwb) return;
                if (typeof bwb.activateScriptEditorTab === 'function') bwb.activateScriptEditorTab();
                else if (typeof bwb.showWidget === 'function') bwb.showWidget('pine-editor');
              })()
            JS
            session.evaluate(<<~JS)
              (function() {
                var btn = document.querySelector('[aria-label="Pine"]')
                  || document.querySelector('[data-name="pine-dialog-button"]');
                if (btn) btn.click();
              })()
            JS
          end

          # Wraps a JS body that needs `m.editor` / `m.env`. The body should
          # be an expression returning a value; the wrapper handles the null
          # check and lookup boilerplate.
          def with_editor(body_js, fallback: 'null')
            <<~JS
              (function() {
                var m = #{FIND_JS};
                if (!m) return #{fallback};
                #{body_js}
              })()
            JS
          end
        end
      end
    end
  end
end
