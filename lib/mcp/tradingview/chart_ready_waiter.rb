# frozen_string_literal: true

module MCP
  module TradingView
    # Poll-based "wait until the chart settles" check. Used after symbol or
    # timeframe changes — TV redraws asynchronously, so callers that don't
    # wait will read stale state. Returns true when the chart looks idle,
    # false on timeout (callers verify independently).
    module ChartReadyWaiter
      DEFAULT_TIMEOUT = 10.0
      POLL_INTERVAL   = 0.2
      STABLE_SAMPLES  = 2

      PROBE_JS = <<~JS
        (function() {
          var spinner = document.querySelector('[class*="loader"]')
            || document.querySelector('[class*="loading"]')
            || document.querySelector('[data-name="loading"]');
          var isLoading = spinner && spinner.offsetParent !== null;
          var barCount = -1;
          try { barCount = document.querySelectorAll('[class*="bar"]').length; } catch (e) {}
          var symbolEl = document.querySelector('[data-name="legend-source-title"]')
            || document.querySelector('[class*="title"] [class*="apply-common-tooltip"]');
          var currentSymbol = symbolEl ? symbolEl.textContent.trim() : '';
          return { isLoading: !!isLoading, barCount: barCount, currentSymbol: currentSymbol };
        })()
      JS

      module_function

      def wait(session, expected_symbol: nil, timeout: DEFAULT_TIMEOUT)
        deadline = monotonic_now + timeout
        last_bar_count = -1
        stable = 0

        while monotonic_now < deadline
          state = safe_probe(session)
          unless state
            sleep POLL_INTERVAL
            next
          end

          if state['isLoading'] || !symbol_matches?(state['currentSymbol'], expected_symbol)
            stable = 0
            sleep POLL_INTERVAL
            next
          end

          stable = state['barCount'] == last_bar_count && state['barCount'].positive? ? stable + 1 : 0
          last_bar_count = state['barCount']
          return true if stable >= STABLE_SAMPLES

          sleep POLL_INTERVAL
        end

        false
      end

      def safe_probe(session)
        session.evaluate(PROBE_JS)
      rescue StandardError
        nil
      end

      def symbol_matches?(actual, expected)
        return true if expected.nil? || expected.empty?
        return false if actual.nil? || actual.empty?

        actual.upcase.include?(expected.upcase)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
