# frozen_string_literal: true

require_relative 'base'

module TradingBot
  module Strategies
    # Andrew Aziz's ABCD pullback continuation. Looks back over the most
    # recent N candles to find a thrust (A→B), measures the retracement
    # (B→C), and fires when the latest candle is breaking the C-pivot in
    # the thrust direction with confirming volume.
    #
    # Fully mechanizable from the candle stream — no external data needed.
    module AbcdAziz
      extend Base
      module_function

      LOOKBACK            = 30                  # how far back we hunt for an A→B thrust
      THRUST_ATR_MULT     = 2.0                 # B − A must exceed this × ATR(14)
      RETRACE_MIN         = 0.38
      RETRACE_MAX         = 0.61
      MIN_REL_VOLUME      = 1.2                 # entry candle volume vs prior bars

      # ATR drives the thrust threshold; RELVOL gates the entry candle.
      # EMA(20) is included because Aziz teaches it as the highest-quality
      # confluence pivot for the C-bounce.
      def column_labels = %w[PRICE ATR(14) RELVOL EMA(20)]
      def column_values(v)
        [
          fmt(v.price),
          fmt(v.atr14),
          v.rel_volume.nil? ? '—' : "#{fmt(v.rel_volume)}×",
          fmt(v.ema20)
        ]
      end

      # Bidirectional strategy — BIAS reads which side the pattern points.
      def bias_label = 'BIAS'
      def bias_text(decision) = decision.bias.to_s.upcase
      def hold_horizon = 'intraday (~30m–1h)'

      # Stop = just past the C-pivot; target = projected D, which is the
      # A→B distance projected from C in the direction of the trend.
      # Re-runs pattern detection because the pattern data isn't carried
      # on the Decision struct.
      def exit_levels(values, decision)
        return nil if decision.block?

        pattern = decision.side == 'Buy' ? detect_long_pattern(values) : detect_short_pattern(values)
        return nil unless pattern

        entry  = values.price
        thrust = (pattern[:b] - pattern[:a]).abs
        if decision.side == 'Buy'
          { entry: entry, stop: pattern[:c] * 0.998, target: pattern[:c] + thrust }
        else
          { entry: entry, stop: pattern[:c] * 1.002, target: pattern[:c] - thrust }
        end
      end

      def call(values)
        return missing_data_decision(%w[atr14]) if values.atr14.nil?
        return missing_data_decision(%w[candles]) if values.candles.nil? || values.candles.length < LOOKBACK + 5

        pattern = detect_long_pattern(values) || detect_short_pattern(values)
        return neutral_decision(reason: 'No ABCD setup in lookback window') unless pattern

        if pattern[:side] == :long
          long_decision(values, pattern)
        else
          short_decision(values, pattern)
        end
      end

      # ── Pattern detection ──────────────────────────────────────────────────

      def detect_long_pattern(values)
        candles = values.candles.last(LOOKBACK)
        # B = highest high in the lookback (the top of the thrust)
        b_idx  = candles.each_with_index.max_by { |c, _| c.high }.last
        b_high = candles[b_idx].high
        # A = lowest low BEFORE B (anchor of the thrust)
        return nil if b_idx.zero?

        a_low = candles[0..b_idx - 1].map(&:low).min
        thrust = b_high - a_low
        return nil if thrust < THRUST_ATR_MULT * values.atr14

        # C = lowest low AFTER B (bottom of the pullback)
        return nil if b_idx >= candles.length - 1

        post_b = candles[(b_idx + 1)..]
        c_low  = post_b.map(&:low).min
        retrace_pct = (b_high - c_low) / thrust.to_f
        return nil unless retrace_pct.between?(RETRACE_MIN, RETRACE_MAX)

        # Latest candle should be trying to break the C-pivot upward.
        last = candles.last
        return nil unless last.close > last.open && last.close > c_low

        { side: :long, a: a_low, b: b_high, c: c_low, retrace_pct: retrace_pct }
      end

      def detect_short_pattern(values)
        candles = values.candles.last(LOOKBACK)
        b_idx  = candles.each_with_index.min_by { |c, _| c.low }.last
        b_low  = candles[b_idx].low
        return nil if b_idx.zero?

        a_high = candles[0..b_idx - 1].map(&:high).max
        thrust = a_high - b_low
        return nil if thrust < THRUST_ATR_MULT * values.atr14

        return nil if b_idx >= candles.length - 1

        post_b = candles[(b_idx + 1)..]
        c_high = post_b.map(&:high).max
        retrace_pct = (c_high - b_low) / thrust.to_f
        return nil unless retrace_pct.between?(RETRACE_MIN, RETRACE_MAX)

        last = candles.last
        return nil unless last.close < last.open && last.close < c_high

        { side: :short, a: a_high, b: b_low, c: c_high, retrace_pct: retrace_pct }
      end

      # ── Decision builders ──────────────────────────────────────────────────

      def long_decision(values, pattern)
        decision(
          side: 'Buy', bias: :bullish,
          conditions: pattern_conditions(values, pattern, direction: :long)
        )
      end

      def short_decision(values, pattern)
        decision(
          side: 'Sell', bias: :bearish,
          conditions: pattern_conditions(values, pattern, direction: :short)
        )
      end

      def pattern_conditions(values, pattern, direction:)
        thrust = (pattern[:b] - pattern[:a]).abs
        atr_mult = thrust / values.atr14
        breakout_label = direction == :long ? 'Last candle bullish (close > open, breaking C)' :
                                              'Last candle bearish (close < open, breaking C)'
        last = values.candles.last
        breakout_pass = direction == :long ? (last.close > last.open && last.close > pattern[:c]) :
                                             (last.close < last.open && last.close < pattern[:c])

        [
          condition(label: "A→B thrust ≥ #{THRUST_ATR_MULT}× ATR(14)",
                    required: "≥ #{fmt(THRUST_ATR_MULT * values.atr14)}",
                    actual: fmt(thrust),
                    pass: thrust >= THRUST_ATR_MULT * values.atr14),
          condition(label: 'Retracement in [38%, 61%]',
                    required: "#{(RETRACE_MIN * 100).to_i}%–#{(RETRACE_MAX * 100).to_i}%",
                    actual: "#{fmt(pattern[:retrace_pct] * 100)}%",
                    pass: pattern[:retrace_pct].between?(RETRACE_MIN, RETRACE_MAX)),
          condition(label: breakout_label,
                    required: 'reversal candle at C',
                    actual: "close=#{fmt(last.close)}, open=#{fmt(last.open)}",
                    pass: breakout_pass),
          condition(label: "Entry volume ≥ #{MIN_REL_VOLUME}× recent average",
                    required: "≥ #{MIN_REL_VOLUME}",
                    actual: fmt(values.rel_volume),
                    pass: values.rel_volume && values.rel_volume >= MIN_REL_VOLUME),
          condition(label: 'Thrust strength (sanity)',
                    required: 'ATR multiple computed',
                    actual: "#{fmt(atr_mult)}× ATR",
                    pass: atr_mult.finite?)
        ]
      end
    end
  end
end
