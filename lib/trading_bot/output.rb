# frozen_string_literal: true

require 'time'

module TradingBot
  # Renders the trading bot's run as a single table — config + trade-limit
  # block at the top, one row per symbol, footer pointing at the JSON log.
  #
  # The strategy-specific indicator columns (PRICE/EMA/VWAP/etc) are NOT
  # baked in. Output looks up the active strategy module via
  # SafetyCheck::REGISTRY and asks it for `column_labels` + `column_values`.
  # That keeps each strategy's table relevant to the inputs it actually
  # gates on — Cameron sees GAP%/RELVOL, Qullamaggie sees SMA(50)/ADR%,
  # Aziz sees ATR(14), etc.
  class Output
    SYMBOL_WIDTH    = 8
    INDICATOR_WIDTH = 9
    BIAS_WIDTH      = 8
    SEPARATOR_WIDTH = 130
    DECISION_TRIM   = 70

    def initialize(config:, strategy:, io: $stdout)
      @config          = config
      @strategy        = strategy
      @strategy_module = SafetyCheck::REGISTRY.fetch(strategy.key)
      @io              = io
      @column_labels   = @strategy_module.column_labels
      @row_format      = build_row_format(@column_labels.size)
    end

    def header
      bar = '═' * SEPARATOR_WIDTH
      @io.puts bar
      @io.puts "  Claude Trading Bot — Decision-only (no execution)  |  #{Time.now.utc.iso8601}"
      @io.puts "  Strategy: #{@strategy.name} (#{@strategy.key})  |  Timeframe: #{@strategy.timeframe}"
      @io.puts "  Universe: #{universe_size} symbols (#{universe_source})"
      @io.puts bar
    end

    # The strategy's `applicable_symbols` (if set) overrides the watchlist —
    # it IS the scan universe. We label which source the count came from so
    # the user can tell at a glance whether a strategy is on its own list
    # or pulling from the global watchlist.
    def universe_size
      @strategy.applicable_symbols&.size || @config.watchlist.size
    end

    def universe_source
      @strategy.applicable_symbols ? 'applicable_symbols' : 'watchlist'
    end

    # Renders a single one-line summary of where we sit on the daily decision
    # cap plus the suggested per-trade notional.
    def trade_limits(today_count:, ok:)
      if ok
        @io.puts "  Decisions today: #{today_count}/#{@config.max_trades_per_day}  |  " \
                 "Suggested size: $#{format('%.2f', @config.trade_size)} (max $#{format('%.2f', @config.max_trade_size)})"
      else
        @io.puts "🚫 Max decisions/day reached: #{today_count}/#{@config.max_trades_per_day}"
      end
    end

    def table_header
      headers = ['SYMBOL', *@column_labels, @strategy_module.bias_label, 'DECISION']
      @io.puts ''
      @io.puts format(@row_format, *headers)
      @io.puts "  #{'─' * SEPARATOR_WIDTH}"
    end

    # `entry` is the JSON-log record Pipeline builds. Output only reads the
    # subset it needs (quantity, order_placed, order_id, error) — the rest
    # is opaque persistence concern.
    def row(symbol:, values:, decision:, entry:)
      cells = [
        symbol,
        *@strategy_module.column_values(values),
        @strategy_module.bias_text(decision),
        decision_label(decision, entry)
      ]
      @io.puts format(@row_format, *cells)
    end

    def skip_row(symbol:, reason:)
      placeholders = ['—'] * @column_labels.size
      cells = [symbol, *placeholders, '—', reason]
      @io.puts format(@row_format, *cells)
    end

    def footer(log_path:)
      @io.puts "  #{'─' * SEPARATOR_WIDTH}"
      @io.puts ''
      @io.puts "  Decision log → #{log_path}"
      @io.puts '═' * SEPARATOR_WIDTH
    end

    # Free-form one-liner for messages that don't fit the table (e.g. fatal
    # auth errors before the table is opened). Use sparingly — most output
    # should flow through the structured methods above.
    def message(text)
      @io.puts text
    end

    private

    # Builds a printf-style format string sized for the active strategy's
    # column count. Symbol cell is left-aligned; numeric indicator cells
    # are right-aligned (so decimal points line up); BIAS is left-aligned;
    # DECISION takes whatever's left.
    def build_row_format(indicator_count)
      symbol_part    = "  %-#{SYMBOL_WIDTH}s"
      indicator_part = (["%#{INDICATOR_WIDTH}s"] * indicator_count).join('  ')
      tail_part      = "%-#{BIAS_WIDTH}s  %s"
      [symbol_part, indicator_part, tail_part].join('  ')
    end

    # Bot is decision-only: no orders, ever. So this column shows either
    #   • the first failed condition for blocked rows; or
    #   • a fully-specified trade idea (LONG/SHORT @ entry, SL, TP, hold-
    #     horizon) for finalized rows so the user can act on it manually.
    def decision_label(decision, entry)
      return "🚫 BLOCKED — #{block_reason(decision)}" if decision.block?
      return '🚫 qty 0 (size < 1 share at suggested $)' if entry['quantity'] < 1

      direction = decision.side == 'Buy' ? 'LONG' : 'SHORT'
      qty       = entry['quantity']
      levels    = entry['levels'] || {}
      horizon   = entry['hold_horizon']
      parts     = ["✅ #{direction}", "#{qty}sh"]
      parts << "@#{format('%.2f', levels['entry'])}"  if levels['entry']
      parts << "SL #{format('%.2f', levels['stop'])}" if levels['stop']
      parts << "TP #{format('%.2f', levels['target'])}" if levels['target']
      parts << "hold:#{horizon}" if horizon
      trim(parts.join(' '), DECISION_TRIM)
    end

    def block_reason(decision)
      first_failed = decision.failed_conditions.first
      first_failed ? trim(first_failed.label, DECISION_TRIM - 8) : 'no clear bias'
    end

    def trim(str, max)
      s = str.to_s
      s.length > max ? "#{s[0, max - 1]}…" : s
    end
  end
end
