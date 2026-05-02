# frozen_string_literal: true

require 'time'

module TradingBot
  # Renders an end-of-tick block: every finalized (non-blocked) decision
  # made in the current scheduler tick, alongside what every other ACTIVE
  # strategy most recently said about the same symbol.
  #
  # Cross-referencing intentionally uses each strategy's most recent log
  # entry — even if it's stale (e.g. a 1D strategy that ran 18h ago) —
  # because that's still the most informed cross-strategy view available.
  # Each row notes the age so the user can weigh freshness.
  class TickSummary
    BAR_WIDTH = 100

    def initialize(io: $stdout)
      @io = io
    end

    def render(decision_log:, since:, strategies:)
      finalized = finalized_in_tick(decision_log, since)
      return if finalized.empty?

      print_header(finalized.size)
      finalized.each { |entry| print_symbol_block(entry, decision_log, strategies) }
      print_footer
    end

    private

    def finalized_in_tick(log, since)
      (log['trades'] || []).select do |t|
        next false unless t['all_pass'] && t['side']

        ts = safe_time(t['timestamp'])
        ts && ts >= since
      end
    end

    def print_header(count)
      noun = count == 1 ? 'decision' : 'decisions'
      bar  = '═' * BAR_WIDTH
      @io.puts ''
      @io.puts bar
      @io.puts "  Tick summary — #{count} finalized #{noun}"
      @io.puts bar
    end

    def print_footer
      @io.puts '═' * BAR_WIDTH
    end

    def print_symbol_block(primary_entry, log, strategies)
      symbol = primary_entry['symbol']
      @io.puts ''
      @io.puts "  ── #{symbol} ──"

      strategies.each do |spec|
        if spec.key == primary_entry['strategy']
          render_finalized(spec.key, primary_entry)
        else
          render_other_strategy_view(spec.key, latest_entry(log, symbol, spec.key))
        end
      end
    end

    def render_finalized(strategy_key, entry)
      direction = entry['side'] == 'Buy' ? 'LONG' : 'SHORT'
      levels    = entry['levels'] || {}
      parts     = []
      parts << "@#{format('%.2f', levels['entry'])}"  if levels['entry']
      parts << "SL #{format('%.2f', levels['stop'])}" if levels['stop']
      parts << "TP #{format('%.2f', levels['target'])}" if levels['target']
      parts << "hold:#{entry['hold_horizon']}" if entry['hold_horizon']
      detail = parts.empty? ? '' : "  #{parts.join(' ')}"
      @io.puts "    ✅ #{strategy_key.ljust(28)} #{direction}#{detail}"
    end

    def render_other_strategy_view(strategy_key, entry)
      if entry.nil?
        @io.puts "    —  #{strategy_key.ljust(28)} no recent run"
        return
      end

      age = age_string(entry['timestamp'])
      if entry['all_pass'] && entry['side']
        # Another finalized decision for the same symbol from a different
        # strategy — agreement is interesting, surface it identically.
        render_finalized(strategy_key, entry)
      else
        reason = first_failed_reason(entry) || 'no clear bias'
        @io.puts "    🚫 #{strategy_key.ljust(28)} BLOCKED — #{reason} (#{age})"
      end
    end

    def latest_entry(log, symbol, strategy_key)
      (log['trades'] || []).reverse_each.find do |t|
        t['symbol'] == symbol && t['strategy'] == strategy_key
      end
    end

    def first_failed_reason(entry)
      failed = (entry['conditions'] || []).find { |c| !c['pass'] }
      failed && failed['label']
    end

    def age_string(iso_timestamp)
      ts = safe_time(iso_timestamp)
      return 'unknown' unless ts

      seconds = Time.now - ts
      return "#{seconds.to_i}s ago"      if seconds < 60
      return "#{(seconds / 60).to_i}m ago"   if seconds < 3600
      return "#{(seconds / 3600).to_i}h ago" if seconds < 86_400

      "#{(seconds / 86_400).to_i}d ago"
    end

    def safe_time(iso_timestamp)
      Time.iso8601(iso_timestamp.to_s)
    rescue StandardError
      nil
    end
  end
end
