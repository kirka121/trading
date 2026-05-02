# frozen_string_literal: true

require_relative 'base'

module TradingBot
  module Strategies
    # Ross Cameron's Gap & Go — long-only momentum continuation on stocks
    # gapping >4% on heavy volume.
    #
    # SCANNER MODE. The full Cameron workflow scans the entire US market
    # pre-market for fresh gappers; a static list of symbols can never
    # substitute for that. Rather than pretend, this strategy declares
    # itself a SCANNER: it iterates a wide universe (its `applicable_symbols`
    # in rules.json), evaluates each symbol's gap-and-volume profile, ranks
    # them by `scanner_score`, and surfaces only the top N candidates that
    # pass the entry rules. Pipeline detects scanner mode via `scanner?`.
    #
    # Two of Cameron's hand-traded checks aren't computable from Questrade
    # daily candles — the pre-market-high break and the <20M-share float
    # filter. Earlier versions made those hard gates that always failed,
    # which made the scanner produce zero output. They're now informational
    # only (in the strategy description). The bot scores on what it CAN
    # measure: gap %, relative volume, VWAP hold, EMA(9) trend.
    module GapAndGoCameron
      extend Base
      module_function

      MIN_GAP_PCT       = 4.0
      MIN_REL_VOLUME    = 5.0

      # ── Scanner contract ───────────────────────────────────────────────

      def scanner?      = true
      def scanner_top_n = 20

      # Higher = stronger Cameron-style setup. We multiply the two primary
      # gates: bigger gap × heavier relative volume = more conviction. A
      # nil from either input collapses the score so missing-data symbols
      # sort to the bottom.
      def scanner_score(values, _decision)
        return nil if values.gap_pct.nil? || values.rel_volume.nil?

        values.gap_pct * values.rel_volume
      end

      # ── Output column contract ─────────────────────────────────────────

      def column_labels = %w[PRICE GAP% RELVOL VWAP EMA(9)]
      def column_values(v)
        [
          fmt(v.price),
          v.gap_pct.nil? ? '—' : "#{fmt(v.gap_pct)}%",
          v.rel_volume.nil? ? '—' : "#{fmt(v.rel_volume)}×",
          fmt(v.vwap),
          fmt(v.ema9)
        ]
      end

      def bias_label = 'REGIME'
      def bias_text(decision) = decision.bias == :bullish ? 'WATCH' : 'SKIP'
      def hold_horizon = 'intraday (≤90m)'

      def regime_in?(values)
        return false if values.gap_pct.nil? || values.vwap.nil?

        values.gap_pct.positive? && values.price > values.vwap
      end

      # Cameron sizes winners at 2R against a ~1% stop (or breakout-candle
      # low — 1% is the conservative computable proxy on daily candles).
      def exit_levels(values, decision)
        return nil if decision.block?

        entry = values.price
        stop  = entry * 0.99
        risk  = entry - stop
        { entry: entry, stop: stop, target: entry + (2 * risk) }
      end

      # ── Decision ───────────────────────────────────────────────────────

      def call(values)
        missing = required_inputs_missing(values)
        return missing_data_decision(missing) unless missing.empty?

        conditions = [
          condition(label: "Gap ≥ #{MIN_GAP_PCT}%",
                    required: "≥ #{MIN_GAP_PCT}%",
                    actual: "#{fmt(values.gap_pct)}%",
                    pass: values.gap_pct >= MIN_GAP_PCT),
          condition(label: "Relative volume ≥ #{MIN_REL_VOLUME}× (50-bar avg)",
                    required: "≥ #{MIN_REL_VOLUME}",
                    actual: "#{fmt(values.rel_volume)}×",
                    pass: values.rel_volume >= MIN_REL_VOLUME),
          condition(label: 'Price above VWAP (gap holding)',
                    required: "> #{fmt(values.vwap)}",
                    actual: fmt(values.price),
                    pass: values.price > values.vwap),
          condition(label: 'Price above EMA(9) (momentum intact)',
                    required: "> #{fmt(values.ema9)}",
                    actual: fmt(values.price),
                    pass: values.price > values.ema9)
        ]

        decision(
          side: 'Buy',
          bias: regime_in?(values) ? :bullish : :neutral,
          conditions: conditions
        )
      end

      def required_inputs_missing(values)
        missing = []
        missing << 'gap_pct' if values.gap_pct.nil?
        missing << 'rel_volume' if values.rel_volume.nil?
        missing << 'vwap' if values.vwap.nil?
        missing << 'ema9' if values.ema9.nil?
        missing
      end
    end
  end
end
