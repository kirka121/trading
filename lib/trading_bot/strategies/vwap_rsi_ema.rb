# frozen_string_literal: true

require_relative 'base'

module TradingBot
  module Strategies
    # VWAP + RSI(3) + EMA(8) intraday strategy. Bullish when price is above
    # both VWAP and EMA(8); enters long when RSI(3) snaps back below 30.
    # Mirror image for shorts. Skips when price is too far from VWAP.
    module VwapRsiEma
      extend Base
      module_function

      MAX_VWAP_DISTANCE_PCT = 1.5
      BULLISH_RSI_THRESHOLD = 30
      BEARISH_RSI_THRESHOLD = 70

      # Output columns specific to this strategy. Each column maps an
      # IndicatorValues field to a formatted cell so the table header +
      # data row stay in lockstep.
      def column_labels = %w[PRICE EMA(8) VWAP RSI(3)]
      def column_values(v)
        [fmt(v.price), fmt(v.ema8), fmt(v.vwap), fmt(v.rsi3)]
      end

      # Bidirectional strategy — BIAS reads the current market lean.
      def bias_label = 'BIAS'
      def bias_text(decision) = decision.bias.to_s.upcase

      # Suggested holding horizon for a typical winner — used in the
      # finalized DECISION cell. Distinct from `default_timeframe` (the
      # candle interval the bot polls): horizon is "how long until the
      # trade is meant to be closed if it works".
      def hold_horizon = 'intraday (~30m)'

      # Concrete entry / stop / target for a finalized decision. Stop is
      # the strategy's hard 0.3% rule; target is 2R against that stop —
      # an honest proxy for the "next VWAP touch / EMA(8) cross / RSI > 50"
      # exit which the bot can't simulate forward.
      def exit_levels(values, decision)
        return nil if decision.block?

        entry = values.price
        risk_pct = 0.003
        if decision.side == 'Buy'
          { entry: entry, stop: entry * (1 - risk_pct), target: entry * (1 + 2 * risk_pct) }
        else
          { entry: entry, stop: entry * (1 + risk_pct), target: entry * (1 - 2 * risk_pct) }
        end
      end

      def call(values)
        return missing_data_decision(%w[vwap rsi3]) if values.vwap.nil? || values.rsi3.nil?

        if bullish?(values)
          long_decision(values)
        elsif bearish?(values)
          short_decision(values)
        else
          neutral_decision(reason: 'Neutral')
        end
      end

      def bullish?(v) = v.price > v.vwap && v.price > v.ema8
      def bearish?(v) = v.price < v.vwap && v.price < v.ema8

      def long_decision(v)
        decision(
          side: 'Buy', bias: :bullish,
          conditions: [
            condition(label: 'Price above VWAP (buyers in control)',
                      required: "> #{fmt(v.vwap)}", actual: fmt(v.price), pass: v.price > v.vwap),
            condition(label: 'Price above EMA(8) (uptrend confirmed)',
                      required: "> #{fmt(v.ema8)}", actual: fmt(v.price), pass: v.price > v.ema8),
            condition(label: "RSI(3) below #{BULLISH_RSI_THRESHOLD} (snap-back setup in uptrend)",
                      required: "< #{BULLISH_RSI_THRESHOLD}", actual: fmt(v.rsi3),
                      pass: v.rsi3 < BULLISH_RSI_THRESHOLD),
            vwap_distance_condition(v)
          ]
        )
      end

      def short_decision(v)
        decision(
          side: 'Sell', bias: :bearish,
          conditions: [
            condition(label: 'Price below VWAP (sellers in control)',
                      required: "< #{fmt(v.vwap)}", actual: fmt(v.price), pass: v.price < v.vwap),
            condition(label: 'Price below EMA(8) (downtrend confirmed)',
                      required: "< #{fmt(v.ema8)}", actual: fmt(v.price), pass: v.price < v.ema8),
            condition(label: "RSI(3) above #{BEARISH_RSI_THRESHOLD} (reversal setup in downtrend)",
                      required: "> #{BEARISH_RSI_THRESHOLD}", actual: fmt(v.rsi3),
                      pass: v.rsi3 > BEARISH_RSI_THRESHOLD),
            vwap_distance_condition(v)
          ]
        )
      end

      def vwap_distance_condition(v)
        dist_pct = ((v.price - v.vwap).abs / v.vwap) * 100
        condition(
          label:    "Price within #{MAX_VWAP_DISTANCE_PCT}% of VWAP (not overextended)",
          required: "< #{MAX_VWAP_DISTANCE_PCT}%",
          actual:   "#{fmt(dist_pct)}%",
          pass:     dist_pct < MAX_VWAP_DISTANCE_PCT
        )
      end
    end
  end
end
