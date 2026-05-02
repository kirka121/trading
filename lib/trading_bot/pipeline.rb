# frozen_string_literal: true

require 'json'

module TradingBot
  # Orchestrates one decision cycle for ONE strategy. Computes a Decision per
  # symbol on the strategy's timeframe and hands the data to Output for
  # rendering — Pipeline never writes to stdout directly, and never places
  # orders. Questrade is used purely for read-only market data.
  class Pipeline
    def initialize(
      config:,
      strategy:,
      logger: TradeLogger.new(csv_path: config.csv_path, json_path: config.decision_log_path),
      output: Output.new(config: config, strategy: strategy)
    )
      @config           = config
      @strategy         = strategy
      @strategy_module  = SafetyCheck::REGISTRY.fetch(strategy.key)
      @logger           = logger
      @output           = output
      @client           = build_client
      @market_data      = Questrade::MarketData.new(client: @client)
    end

    def call
      @output.header
      @logger.initialize_csv_if_missing

      decision_log = @logger.load_decision_log
      today_count  = @logger.count_todays_decisions(decision_log)
      if today_count >= @config.max_trades_per_day && !scanner_mode?
        @output.trade_limits(today_count: today_count, ok: false)
        return
      end
      @output.trade_limits(today_count: today_count, ok: true)

      @client.authenticate!

      if scanner_mode?
        run_scanner(decision_log)
      else
        run_per_symbol(decision_log)
      end

      @output.footer(log_path: @config.decision_log_path)
    end

    private

    # Scanner-mode strategies (e.g. Cameron's Gap & Go) opt in by responding
    # to `scanner?`. They iterate a wide universe, score every result, and
    # surface only the top N matches — bypassing the daily-decision cap so
    # the user sees the full top-N list every run.
    def scanner_mode?
      @strategy_module.respond_to?(:scanner?) && @strategy_module.scanner?
    end

    # Standard per-symbol render: one table row per applicable watchlist
    # entry, in iteration order.
    def run_per_symbol(decision_log)
      @output.table_header

      applicable_watchlist.each do |entry|
        decision_log = @logger.load_decision_log
        if @logger.count_todays_decisions(decision_log) >= @config.max_trades_per_day
          @output.skip_row(symbol: entry.label, reason: '— daily decision cap reached')
          break
        end
        process_entry(entry, decision_log)
      end
    end

    # Scanner render: evaluate every symbol in the universe, keep only the
    # ones whose Decision is finalized (all conditions passed), rank by
    # the strategy's score function, surface the top N. Logs only the
    # surfaced rows so the JSON log doesn't fill with rejected candidates.
    def run_scanner(decision_log)
      results = applicable_watchlist.filter_map { |entry| evaluate_for_scanner(entry, decision_log) }

      matches = results.select { |r| r[:decision].all_pass }
      ranked  = matches.sort_by { |r| -(r[:score] || -Float::INFINITY) }
                       .first(@strategy_module.scanner_top_n)

      @output.message(
        "  Scanned #{results.size} symbols • #{matches.size} matched entry rules • showing top #{ranked.size}"
      )
      @output.table_header

      if ranked.empty?
        @output.message('  No candidates matched entry rules in this scan.')
        return
      end

      ranked.each do |r|
        @output.row(symbol: r[:entry].label, values: r[:values], decision: r[:decision], entry: r[:log_entry])
        @logger.record(r[:log_entry])
      end
    end

    # Builds the data needed to rank a single symbol in scanner mode. Returns
    # nil when the symbol can't be evaluated (no candles, delisted ticker,
    # transient API error) so the scan continues across the rest of the
    # universe instead of crashing on the first bad row. Per-symbol errors
    # go to stderr for visibility without polluting the table.
    def evaluate_for_scanner(entry, decision_log)
      candles = fetch_candles(entry.questrade)
      return nil if candles.empty?

      values    = Indicators.call(candles, timeframe: @strategy.timeframe)
      decision  = SafetyCheck.call(values, strategy_key: @strategy.key)
      score     = @strategy_module.scanner_score(values, decision)
      levels    = @strategy_module.respond_to?(:exit_levels) ? @strategy_module.exit_levels(values, decision) : nil
      log_entry = build_log_entry(entry: entry, values: values, decision: decision, levels: levels, decision_log: decision_log)
      { entry: entry, values: values, decision: decision, score: score, log_entry: log_entry }
    rescue StandardError => e
      warn "  scanner: skipped #{entry.label} — #{e.class}: #{e.message[0, 120]}"
      nil
    end

    # When `applicable_symbols` is set on the strategy, it OVERRIDES the
    # global watchlist — the strategy runs on exactly those symbols, even
    # if some aren't in the watchlist. nil/missing means "fall back to the
    # full watchlist" (default).
    #
    # For each declared symbol we still try to match it against an existing
    # watchlist entry first so divergent pairs like VSP↔VSP.TO are
    # preserved (so Questrade gets the right ticker). Symbols not found in
    # the watchlist get a synthesised entry where both forms equal the
    # input — works for the common case of identical TV/Questrade tickers.
    def applicable_watchlist
      whitelist = @strategy.applicable_symbols
      return @config.watchlist if whitelist.nil?

      whitelist.map { |sym| resolve_entry(sym) }
    end

    def resolve_entry(symbol)
      target = symbol.upcase
      match = @config.watchlist.find do |entry|
        entry.tv.upcase == target || entry.questrade.upcase == target
      end
      match || WatchlistEntry.new(questrade: symbol, tv: symbol)
    end

    def process_entry(entry, decision_log)
      candles = fetch_candles(entry.questrade)
      return @output.skip_row(symbol: entry.label, reason: '— no candles (market closed?)') if candles.empty?

      values     = Indicators.call(candles, timeframe: @strategy.timeframe)
      decision   = SafetyCheck.call(values, strategy_key: @strategy.key)
      levels     = @strategy_module.respond_to?(:exit_levels) ? @strategy_module.exit_levels(values, decision) : nil
      log_entry  = build_log_entry(entry: entry, values: values, decision: decision, levels: levels, decision_log: decision_log)

      @output.row(symbol: entry.label, values: values, decision: decision, entry: log_entry)
      @logger.record(log_entry)
    end

    def build_client
      authenticator = Questrade::Authenticator.new
      Questrade::Client.new(authenticator: authenticator, refresh_token: @config.refresh_token)
    end

    def fetch_candles(questrade_symbol)
      @market_data.fetch_candles(ticker: questrade_symbol, timeframe: @strategy.timeframe, limit: 200)
    rescue Questrade::MarketData::SymbolNotFound
      []
    end

    # Build the JSON-log record. Now decision-only — no order_placed,
    # order_id, paper/practice flags. Adds `levels` so the historical log
    # captures what entry/stop/target the strategy would have suggested.
    def build_log_entry(entry:, values:, decision:, levels:, decision_log:)
      {
        'timestamp'        => Time.now.utc.iso8601,
        'symbol'           => entry.label,
        'questrade_symbol' => entry.questrade,
        'tv_symbol'        => entry.tv,
        'strategy'         => @strategy.key,
        'timeframe'        => @strategy.timeframe,
        'price'            => values.price,
        'indicators'       => { 'ema8' => values.ema8, 'vwap' => values.vwap, 'rsi3' => values.rsi3 },
        'conditions'       => decision.conditions.map(&:to_h).map { |h| h.transform_keys(&:to_s) },
        'all_pass'         => decision.all_pass,
        'side'             => decision.side,
        'bias'             => decision.bias.to_s,
        'levels'           => levels && levels.transform_keys(&:to_s),
        'hold_horizon'     => @strategy_module.respond_to?(:hold_horizon) ? @strategy_module.hold_horizon : nil,
        'trade_size'       => @config.trade_size,
        'quantity'         => quantity_for(values.price),
        'limits' => {
          'max_trade_size'    => @config.max_trade_size,
          'max_decisions_day' => @config.max_trades_per_day,
          'decisions_today'   => @logger.count_todays_decisions(decision_log)
        }
      }
    end

    def quantity_for(price)
      return 0 if price.nil? || price.zero?

      (@config.trade_size / price).floor
    end
  end
end
