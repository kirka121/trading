# frozen_string_literal: true

require_relative 'base'

module TradingBot
  module Strategies
    # Mark Minervini's VCP — Volatility Contraction Pattern breakout.
    #
    # NOTE: this is a SIMPLIFIED implementation. The real strategy demands:
    #   - 2–4 successive contractions of decreasing depth (T1: 25–35%,
    #     T2: 15–20%, T3: 8–12%) — full base detection is non-trivial;
    #   - IBD-style relative-strength rating ≥ 70, which is proprietary
    #     IBD data we don't have access to.
    #
    # We approximate with: stage-2 trend filter, recent-base tightness
    # (proxy for the final contraction), 52w-high proximity, and a volume-
    # confirmed pivot break. The IBD RS rating is replaced with a "price
    # vs. 50 bars ago" momentum proxy. Surfacing this so the user knows the
    # gap from the discretionary version Minervini actually trades.
    module VcpBreakoutMinervini
      extend Base
      module_function

      MIN_RS_PROXY_PCT      = 10.0   # % gain over last 50 bars (rough RS proxy)
      MAX_DIST_FROM_52W_HIGH = 25.0  # %
      FINAL_BASE_BARS       = 10
      MAX_FINAL_BASE_RANGE  = 8.0    # % — tight final contraction
      MIN_PIVOT_VOLUME      = 1.4    # × avg
      MIN_CANDLES           = 200    # need ~200 daily bars for the full filter

      # Stage-2 reference (50/200 SMAs), pivot-break volume, and the
      # 52-week-high gauge are the at-a-glance signals of a Minervini base.
      # Distance-from-52w is computed inside `call`; we recompute it here so
      # the row reflects exactly what gated the decision.
      def column_labels = %w[PRICE SMA(50) SMA(200) 52W% RELVOL]
      def column_values(v)
        dist_52w = v.candles ? compute_distance_from_52w_high(v.candles) : nil
        [
          fmt(v.price),
          fmt(v.sma50),
          fmt(v.sma200),
          dist_52w.nil? ? '—' : "#{fmt(dist_52w)}%",
          v.rel_volume.nil? ? '—' : "#{fmt(v.rel_volume)}×"
        ]
      end

      # Long-only — REGIME asks "is the stock in a stage-2 uptrend?".
      # WATCH = price > rising 50/150/200 SMAs; SKIP = anything else.
      def bias_label = 'REGIME'
      def bias_text(decision) = decision.bias == :bullish ? 'WATCH' : 'SKIP'
      def hold_horizon = '5–14 days'

      def regime_in?(values)
        return false if values.sma50.nil? || values.sma150.nil? || values.sma200.nil?

        stage_2?(values)
      end

      # Minervini's universal "cut at 7-8% loss" rule for the stop.
      # Target = +20% — midpoint of his 15–25% sell-into-strength band.
      def exit_levels(values, decision)
        return nil if decision.block?

        entry = values.price
        { entry: entry, stop: entry * 0.92, target: entry * 1.20 }
      end

      def call(values)
        missing = missing_inputs(values)
        return missing_data_decision(missing) unless missing.empty?

        candles = values.candles
        rs_proxy_pct = compute_rs_proxy_pct(candles)
        dist_52w_pct = compute_distance_from_52w_high(candles)
        final_base   = compute_final_base(candles)
        pivot_break  = values.price > final_base[:high]

        conditions = [
          condition(label: 'Stage 2 — price > rising 50/150/200 SMAs',
                    required: 'all true',
                    actual: stage_2_summary(values),
                    pass: stage_2?(values)),
          condition(label: "Within #{MAX_DIST_FROM_52W_HIGH}% of 52w high",
                    required: "≤ #{MAX_DIST_FROM_52W_HIGH}%",
                    actual: "#{fmt(dist_52w_pct)}%",
                    pass: dist_52w_pct && dist_52w_pct <= MAX_DIST_FROM_52W_HIGH),
          condition(label: "RS proxy: 50-bar return ≥ #{MIN_RS_PROXY_PCT}%",
                    required: "≥ #{MIN_RS_PROXY_PCT}%",
                    actual: "#{fmt(rs_proxy_pct)}%",
                    pass: rs_proxy_pct && rs_proxy_pct >= MIN_RS_PROXY_PCT),
          condition(label: "Tight final base — last #{FINAL_BASE_BARS} bars range ≤ #{MAX_FINAL_BASE_RANGE}%",
                    required: "≤ #{MAX_FINAL_BASE_RANGE}%",
                    actual: "#{fmt(final_base[:range_pct])}%",
                    pass: final_base[:range_pct] <= MAX_FINAL_BASE_RANGE),
          condition(label: 'Pivot break — close above final-base high',
                    required: "> #{fmt(final_base[:high])}",
                    actual: fmt(values.price),
                    pass: pivot_break),
          condition(label: "Pivot volume ≥ #{MIN_PIVOT_VOLUME}× avg",
                    required: "≥ #{MIN_PIVOT_VOLUME}",
                    actual: fmt(values.rel_volume),
                    pass: values.rel_volume && values.rel_volume >= MIN_PIVOT_VOLUME),
          # Honest disclosure of the simplification.
          condition(label: 'Full VCP base structure (T1>T2>T3)',
                    required: 'multi-tier contraction detection',
                    actual: 'simplified — final-base check only',
                    pass: false)
        ]
        decision(side: 'Buy', bias: regime_in?(values) ? :bullish : :neutral, conditions: conditions)
      end

      def missing_inputs(values)
        missing = []
        missing << 'sma50' if values.sma50.nil?
        missing << 'sma150' if values.sma150.nil?
        missing << 'sma200' if values.sma200.nil?
        missing << 'rel_volume' if values.rel_volume.nil?
        if values.candles.nil? || values.candles.length < MIN_CANDLES
          missing << "candles (need ≥ #{MIN_CANDLES}, daily timeframe)"
        end
        missing
      end

      def stage_2?(v)
        v.price > v.sma50 && v.sma50 > v.sma150 && v.sma150 > v.sma200
      end

      def stage_2_summary(v)
        "px=#{fmt(v.price)} 50=#{fmt(v.sma50)} 150=#{fmt(v.sma150)} 200=#{fmt(v.sma200)}"
      end

      # 52w high using the last min(252, len) bars; distance reported as
      # a positive percent — 0% means at the high.
      def compute_distance_from_52w_high(candles)
        window = candles.last([252, candles.length].min)
        high   = window.map(&:high).max
        return nil if high.nil? || high.zero?

        ((high - candles.last.close) / high) * 100.0
      end

      # IBD-RS proxy: % gain over the last 50 closes. Crude, but in trending
      # bull markets correlates with their RS rating.
      def compute_rs_proxy_pct(candles)
        return nil if candles.length < 51

        old_close = candles[-51].close
        return nil if old_close.zero?

        ((candles.last.close - old_close) / old_close) * 100.0
      end

      def compute_final_base(candles)
        recent = candles.last(FINAL_BASE_BARS)
        high   = recent.map(&:high).max
        low    = recent.map(&:low).min
        range_pct = low.zero? ? 0.0 : ((high - low) / low) * 100.0
        { high: high, low: low, range_pct: range_pct }
      end
    end
  end
end
