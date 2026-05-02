# frozen_string_literal: true

require_relative 'base'
require_relative '../known_paths'

module MCP
  module TradingView
    module Tools
      # Replay-mode tools.
      #
      # The replay API exposes some methods that return WatchedValue<T>
      # wrappers and some that return plain values; we normalise both via
      # the `unwrap` JS helper before returning.
      module Replay
        REPLAY_API = KnownPaths::REPLAY_API

        # Unwrap WatchedValue OR pass through scalars in one expression.
        def self.unwrap_js(expression)
          <<~JS.strip
            (function() {
              var v = #{expression};
              return (v && typeof v === 'object' && typeof v.value === 'function') ? v.value() : v;
            })()
          JS
        end

        def self.api(session)
          KnownPaths.verify(session, REPLAY_API, 'Replay API')
        end
        private_class_method :api

        # Replay setup is fragile — TV pops a "Data point unavailable" toast
        # for invalid dates which corrupts the chart unless we recover.
        TOAST_PROBE_JS = <<~JS
          (function() {
            var toasts = document.querySelectorAll('[class*="toast"], [class*="notification"], [class*="banner"]');
            for (var i = 0; i < toasts.length; i++) {
              var text = toasts[i].textContent || '';
              if (/data point unavailable|not available for playback/i.test(text)) {
                return text.trim().substring(0, 200);
              }
            }
            return null;
          })()
        JS

        class Start < Base
          tool_name 'replay_start'
          description 'Enter replay mode for the active chart. Optionally start from a specific date (YYYY-MM-DD).'
          input_schema({
            type: 'object',
            properties: { date: { type: 'string', description: 'Date string parseable by JS Date()' } },
            additionalProperties: false
          })

          def self.perform(date: nil)
            api       = Replay.send(:api, session)
            available = session.evaluate(Replay.unwrap_js("#{api}.isReplayAvailable()"))
            raise 'Replay is not available for the current symbol/timeframe' unless available

            session.evaluate("#{api}.showReplayToolbar()")
            sleep 0.5

            if date && !date.empty?
              session.evaluate("#{api}.selectDate(new Date(#{js_string(date)}))")
            else
              session.evaluate("#{api}.selectFirstAvailableDate()")
            end
            sleep 1.0

            toast = session.evaluate(TOAST_PROBE_JS)
            if toast
              # Best-effort recovery — chart will be wedged otherwise.
              begin session.evaluate("#{api}.stopReplay()") rescue nil end
              begin session.evaluate("#{api}.hideReplayToolbar()") rescue nil end
              raise "Replay date unavailable: \"#{toast}\". The requested date has no data for this timeframe. Try a more recent date or a higher timeframe (e.g., Daily)."
            end

            started      = session.evaluate(Replay.unwrap_js("#{api}.isReplayStarted()"))
            current_date = session.evaluate(Replay.unwrap_js("#{api}.currentDate()"))
            { success: true, replay_started: !!started, date: date || '(first available)', current_date: current_date }
          end
        end

        class Step < Base
          tool_name 'replay_step'
          description 'Advance replay by a single bar.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            api     = Replay.send(:api, session)
            started = session.evaluate(Replay.unwrap_js("#{api}.isReplayStarted()"))
            raise 'Replay is not started. Use replay_start first.' unless started

            session.evaluate("#{api}.doStep()")
            { success: true, action: 'step', current_date: session.evaluate(Replay.unwrap_js("#{api}.currentDate()")) }
          end
        end

        class Autoplay < Base
          tool_name 'replay_autoplay'
          description 'Toggle replay autoplay. Pass `speed` (ms per bar) to set delay before toggling.'
          input_schema({
            type: 'object',
            properties: { speed: { type: 'integer', minimum: 1, description: 'Delay between bars in ms' } },
            additionalProperties: false
          })

          def self.perform(speed: nil)
            api     = Replay.send(:api, session)
            started = session.evaluate(Replay.unwrap_js("#{api}.isReplayStarted()"))
            raise 'Replay is not started. Use replay_start first.' unless started

            session.evaluate("#{api}.changeAutoplayDelay(#{Integer(speed)})") if speed && speed.positive?
            session.evaluate("#{api}.toggleAutoplay()")
            {
              success:        true,
              autoplay_active: !!session.evaluate(Replay.unwrap_js("#{api}.isAutoplayStarted()")),
              delay_ms:        session.evaluate(Replay.unwrap_js("#{api}.autoplayDelay()"))
            }
          end
        end

        class Stop < Base
          tool_name 'replay_stop'
          description 'Exit replay mode and hide the replay toolbar.'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            api     = Replay.send(:api, session)
            started = session.evaluate(Replay.unwrap_js("#{api}.isReplayStarted()"))
            unless started
              begin session.evaluate("#{api}.hideReplayToolbar()") rescue nil end
              return { success: true, action: 'already_stopped' }
            end

            session.evaluate("#{api}.stopReplay()")
            begin session.evaluate("#{api}.hideReplayToolbar()") rescue nil end
            { success: true, action: 'replay_stopped' }
          end
        end

        class Trade < Base
          tool_name 'replay_trade'
          description 'Place a paper trade inside replay mode (buy / sell / close).'
          input_schema({
            type: 'object',
            properties: { action: { type: 'string', enum: %w[buy sell close] } },
            required: ['action'],
            additionalProperties: false
          })

          def self.perform(action:)
            api     = Replay.send(:api, session)
            started = session.evaluate(Replay.unwrap_js("#{api}.isReplayStarted()"))
            raise 'Replay is not started. Use replay_start first.' unless started

            case action
            when 'buy'   then session.evaluate("#{api}.buy()")
            when 'sell'  then session.evaluate("#{api}.sell()")
            when 'close' then session.evaluate("#{api}.closePosition()")
            else raise 'action must be one of: buy, sell, close'
            end

            {
              success:       true,
              action:        action,
              position:      session.evaluate(Replay.unwrap_js("#{api}.position()")),
              realized_pnl:  session.evaluate(Replay.unwrap_js("#{api}.realizedPL()"))
            }
          end
        end

        class Status < Base
          tool_name 'replay_status'
          description 'Read the current replay status (started/autoplay/date/position/PnL).'
          input_schema({ type: 'object', properties: {}, additionalProperties: false })

          def self.perform(**_)
            api    = Replay.send(:api, session)
            status = session.evaluate(<<~JS)
              (function() {
                var r = #{api};
                function unwrap(v) { return (v && typeof v === 'object' && typeof v.value === 'function') ? v.value() : v; }
                return {
                  is_replay_available: unwrap(r.isReplayAvailable()),
                  is_replay_started:   unwrap(r.isReplayStarted()),
                  is_autoplay_started: unwrap(r.isAutoplayStarted()),
                  replay_mode:         unwrap(r.replayMode()),
                  current_date:        unwrap(r.currentDate()),
                  autoplay_delay:      unwrap(r.autoplayDelay())
                };
              })()
            JS
            { success: true }.merge(status).merge(
              position:     session.evaluate(Replay.unwrap_js("#{api}.position()")),
              realized_pnl: session.evaluate(Replay.unwrap_js("#{api}.realizedPL()"))
            )
          end
        end
      end
    end
  end
end
