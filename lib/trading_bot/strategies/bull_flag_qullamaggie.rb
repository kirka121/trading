# frozen_string_literal: true

require_relative 'base'

module TradingBot
  module Strategies
    # Kristjan Kullamägi's stage-2 bull flag breakout. Wants a stock that
    # has just made a sharp run-up, consolidated tightly near the highs,
    # and is now breaking out on volume.
    #
    # Designed for the daily timeframe — needs ~200 daily candles to verify
    # the 200 SMA and the prior 1–3 month vertical move. If you run this on
    # 5m candles the SMAs and prior-move check are meaningless and the
    # missing-data gate fires.
    module BullFlagQullamaggie
      extend Base
      module_function

      LOOKBACK_PRIOR_MOVE = 60        # daily bars for the 30%+ run-up window
      MIN_PRIOR_MOVE_PCT  = 30.0
      CONSOLIDATION_BARS  = 7         # measure tightness on the most recent N bars
      MAX_CONSOLIDATION_RANGE_PCT = 12.0
      MIN_ADR_PCT         = 5.0
      MIN_BREAKOUT_VOLUME = 1.5       # × 50-bar avg volume
      LONG_ONLY           = true      # the strategy is explicitly long-only

      # Stage-2 trend (50/200 SMAs), liquidity (ADR), and breakout volume
      # are what the user actually needs to read off the row.
      def column_labels = %w[PRICE SMA(50) SMA(200) ADR% RELVOL]
      def column_values(v)
        [
          fmt(v.price),
          fmt(v.sma50),
          fmt(v.sma200),
          v.adr20_pct.nil? ? '—' : "#{fmt(v.adr20_pct)}%",
          v.rel_volume.nil? ? '—' : "#{fmt(v.rel_volume)}×"
        ]
      end

      # Long-only — REGIME asks "is the stock in a stage-2 uptrend?".
      # WATCH = price > rising 50/150/200 SMAs; SKIP = anything else.
      def bias_label = 'REGIME'
      def bias_text(decision) = decision.bias == :bullish ? 'WATCH' : 'SKIP'
      def hold_horizon = '3–15 days'

      def regime_in?(values)
        return false if values.sma50.nil? || values.sma150.nil? || values.sma200.nil?

        stage_2?(values)
      end

      # Stop at the consolidation low. Target = +15% — Kristjan sells into
      # strength after 3–5 days; 15% is the typical winner-fraction observed
      # in his own portfolio updates.
      def exit_levels(values, decision)
        return nil if decision.block?
        return nil unless values.candles && values.candles.length >= CONSOLIDATION_BARS

        entry = values.price
        stop  = compute_consolidation(values.candles)[:low]
        { entry: entry, stop: stop, target: entry * 1.15 }
      end

      def call(values)
        missing = missing_inputs(values)
        return missing_data_decision(missing) unless missing.empty?

        candles = values.candles
        prior_move_pct = compute_prior_move_pct(candles)
        consolidation  = compute_consolidation(candles)
        breakout       = compute_breakout(candles, consolidation)

        conditions = [
          condition(label: 'Stage 2 — price > rising 50/150/200 SMAs',
                    required: 'all true',
                    actual: stage_2_summary(values),
                    pass: stage_2?(values)),
          condition(label: "Prior #{LOOKBACK_PRIOR_MOVE}-bar move ≥ #{MIN_PRIOR_MOVE_PCT}%",
                    required: "≥ #{MIN_PRIOR_MOVE_PCT}%",
                    actual: "#{fmt(prior_move_pct)}%",
                    pass: prior_move_pct && prior_move_pct >= MIN_PRIOR_MOVE_PCT),
          condition(label: "Tight #{CONSOLIDATION_BARS}-bar consolidation (range ≤ #{MAX_CONSOLIDATION_RANGE_PCT}%)",
                    required: "≤ #{MAX_CONSOLIDATION_RANGE_PCT}%",
                    actual: "#{fmt(consolidation[:range_pct])}%",
                    pass: consolidation[:range_pct] <= MAX_CONSOLIDATION_RANGE_PCT),
          condition(label: "ADR(20) ≥ #{MIN_ADR_PCT}%",
                    required: "≥ #{MIN_ADR_PCT}%",
                    actual: "#{fmt(values.adr20_pct)}%",
                    pass: values.adr20_pct && values.adr20_pct >= MIN_ADR_PCT),
          condition(label: 'Today closes above consolidation high',
                    required: "> #{fmt(consolidation[:high])}",
                    actual: fmt(values.price),
                    pass: breakout[:closed_above]),
          condition(label: "Breakout volume ≥ #{MIN_BREAKOUT_VOLUME}× avg",
                    required: "≥ #{MIN_BREAKOUT_VOLUME}",
                    actual: fmt(values.rel_volume),
                    pass: values.rel_volume && values.rel_volume >= MIN_BREAKOUT_VOLUME)
        ]
        decision(side: 'Buy', bias: regime_in?(values) ? :bullish : :neutral, conditions: conditions)
      end

      def missing_inputs(values)
        missing = []
        missing << 'sma50' if values.sma50.nil?
        missing << 'sma150' if values.sma150.nil?
        missing << 'sma200' if values.sma200.nil?
        missing << 'adr20_pct' if values.adr20_pct.nil?
        missing << 'rel_volume' if values.rel_volume.nil?
        if values.candles.nil? || values.candles.length < LOOKBACK_PRIOR_MOVE + CONSOLIDATION_BARS
          missing << "candles (need ≥ #{LOOKBACK_PRIOR_MOVE + CONSOLIDATION_BARS}, daily timeframe)"
        end
        missing
      end

      def stage_2?(v)
        v.price > v.sma50 &&
          v.sma50 > v.sma150 &&
          v.sma150 > v.sma200
      end

      def stage_2_summary(v)
        "price=#{fmt(v.price)} sma50=#{fmt(v.sma50)} sma150=#{fmt(v.sma150)} sma200=#{fmt(v.sma200)}"
      end

      # Largest pct gain (close-to-close) within the last LOOKBACK_PRIOR_MOVE bars.
      # Approximates "made a 30%+ move in the last 1–3 months".
      def compute_prior_move_pct(candles)
        window = candles.last(LOOKBACK_PRIOR_MOVE)
        return nil if window.length < 2

        closes = window.map(&:close)
        max_close = closes.max
        min_before_max = closes.first(closes.index(max_close) + 1).min
        return nil if min_before_max.zero?

        ((max_close - min_before_max) / min_before_max) * 100.0
      end

      # High/low/range of the last CONSOLIDATION_BARS daily bars.
      def compute_consolidation(candles)
        recent = candles.last(CONSOLIDATION_BARS)
        high   = recent.map(&:high).max
        low    = recent.map(&:low).min
        range_pct = low.zero? ? 0.0 : ((high - low) / low) * 100.0
        { high: high, low: low, range_pct: range_pct }
      end

      def compute_breakout(candles, consolidation)
        last_close = candles.last.close
        { closed_above: last_close > consolidation[:high] }
      end
    end
  end
end
