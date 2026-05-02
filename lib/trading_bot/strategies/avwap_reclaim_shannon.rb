# frozen_string_literal: true

require_relative 'base'

module TradingBot
  module Strategies
    # Brian Shannon's anchored-VWAP reclaim. Anchors VWAP to the most recent
    # significant gap day (proxy for "earnings / news event"), then waits for
    # price to reclaim that AVWAP after a sustained period below it.
    #
    # The "anchor" pick is automated — Brian himself picks anchors by hand
    # (earnings, ATH, swing low). The most-recent-gap heuristic captures the
    # spirit but won't always match what he'd pick. Daily timeframe.
    module AvwapReclaimShannon
      extend Base
      module_function

      LOOKBACK              = 90    # how far back to scan for an anchor gap
      MIN_ANCHOR_GAP_PCT    = 3.0   # gap-day threshold (close-to-open jump)
      MIN_DAYS_BELOW_AVWAP  = 5     # how long price had to be under AVWAP before reclaim
      MIN_RECLAIM_VOLUME    = 1.0   # × 50-bar avg
      MIN_CANDLES           = 30

      # AVWAP itself is computed dynamically from the auto-picked anchor (it
      # isn't a static IndicatorValues field), so it lives in the Decision
      # conditions rather than the table. The columns surface the surrounding
      # context: trend reference (EMA(20)), volume confirmation, and the most
      # recent gap magnitude (the candidate for the next anchor).
      def column_labels = %w[PRICE EMA(20) RELVOL LASTGAP%]
      def column_values(v)
        [
          fmt(v.price),
          fmt(v.ema20),
          v.rel_volume.nil? ? '—' : "#{fmt(v.rel_volume)}×",
          v.gap_pct.nil? ? '—' : "#{fmt(v.gap_pct)}%"
        ]
      end

      # Long-only — REGIME asks "has price reclaimed the anchor AVWAP?".
      # WATCH = price > AVWAP (the reclaim has happened or is current);
      # SKIP = no anchor found, missing data, or still under AVWAP.
      def bias_label = 'REGIME'
      def bias_text(decision) = decision.bias == :bullish ? 'WATCH' : 'SKIP'
      def hold_horizon = '1–10 days'

      # Stop = 1× ATR below the anchor AVWAP (Shannon's heuristic).
      # Target = entry + 2R against that stop. AVWAP is recomputed because
      # it isn't carried on Decision.
      def exit_levels(values, decision)
        return nil if decision.block?

        candles = values.candles
        return nil unless candles && values.atr14

        anchor_idx = find_anchor_idx(candles)
        return nil if anchor_idx.nil?

        avwap_value = Indicators::AnchoredVWAP.call(candles, anchor_idx: anchor_idx)
        return nil if avwap_value.nil?

        entry = values.price
        stop  = avwap_value - values.atr14
        risk  = entry - stop
        { entry: entry, stop: stop, target: entry + (2 * risk) }
      end

      def call(values)
        candles = values.candles
        return missing_data_decision(["candles (need ≥ #{MIN_CANDLES})"]) if candles.nil? || candles.length < MIN_CANDLES

        anchor_idx = find_anchor_idx(candles)
        return neutral_decision(reason: "No anchor gap ≥ #{MIN_ANCHOR_GAP_PCT}% in last #{LOOKBACK} bars") if anchor_idx.nil?

        avwap_value = Indicators::AnchoredVWAP.call(candles, anchor_idx: anchor_idx)
        return missing_data_decision(['anchored_vwap']) if avwap_value.nil?

        reclaim = reclaim_state(candles, anchor_idx, avwap_value)

        conditions = [
          condition(label: "Anchor gap day (≥ #{MIN_ANCHOR_GAP_PCT}%)",
                    required: 'anchor identified',
                    actual: "#{candles.length - anchor_idx} bars ago",
                    pass: true),
          condition(label: "Price was below AVWAP for ≥ #{MIN_DAYS_BELOW_AVWAP} bars",
                    required: "≥ #{MIN_DAYS_BELOW_AVWAP}",
                    actual: "#{reclaim[:days_below]} bars",
                    pass: reclaim[:days_below] >= MIN_DAYS_BELOW_AVWAP),
          condition(label: 'Latest close above AVWAP',
                    required: "> #{fmt(avwap_value)}",
                    actual: fmt(values.price),
                    pass: values.price > avwap_value),
          condition(label: "Reclaim volume ≥ #{MIN_RECLAIM_VOLUME}× avg",
                    required: "≥ #{MIN_RECLAIM_VOLUME}",
                    actual: fmt(values.rel_volume),
                    pass: values.rel_volume && values.rel_volume >= MIN_RECLAIM_VOLUME)
        ]
        decision(side: 'Buy', bias: values.price > avwap_value ? :bullish : :neutral, conditions: conditions)
      end

      # Walks the recent candles backwards from `length - 2` to `length - LOOKBACK`
      # looking for a gap (open vs prior close) that exceeds the threshold.
      # Returns the index of the FIRST candle of that anchor day, so AVWAP
      # accumulates from that bar onward.
      def find_anchor_idx(candles)
        end_idx   = candles.length - 2  # don't anchor on the most recent (still-forming) bar
        start_idx = [end_idx - LOOKBACK + 1, 1].max
        end_idx.downto(start_idx) do |i|
          prior_close = candles[i - 1].close
          next if prior_close.zero?

          gap_pct = ((candles[i].open - prior_close) / prior_close).abs * 100.0
          return i if gap_pct >= MIN_ANCHOR_GAP_PCT
        end
        nil
      end

      # How many bars in a row, ending at the bar just before the latest,
      # closed below AVWAP. Captures Shannon's "spent time under AVWAP" idea
      # without needing the full path history.
      def reclaim_state(candles, anchor_idx, avwap_value)
        # Start from the bar before the latest, walk backwards while close < avwap.
        end_idx = candles.length - 2
        start   = [anchor_idx, 0].max
        days_below = 0
        end_idx.downto(start) do |i|
          break if candles[i].close >= avwap_value

          days_below += 1
        end
        { days_below: days_below }
      end
    end
  end
end
