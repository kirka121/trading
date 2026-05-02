# frozen_string_literal: true

module TradingBot
  # Stateless indicator calculators. Each is a service object exposing `.call`.
  module Indicators
    # Number of US RTH minutes in a session (6.5h × 60min) — used to anchor
    # VWAP to "today's session".
    SESSION_MINUTES = 390

    MINUTES_PER_CANDLE = {
      '1m' => 1, '2m' => 2, '3m' => 3, '5m' => 5, '15m' => 15,
      '30m' => 30, '1H' => 60, '4H' => 240, '1D' => 1440
    }.freeze

    module_function

    # Returns an IndicatorValues snapshot from a sequence of Candles.
    def call(candles, timeframe:)
      closes = candles.map(&:close)
      IndicatorValues.new(
        price: closes.last,
        ema8:  EMA.call(closes, period: 8),
        vwap:  VWAP.call(candles, timeframe: timeframe),
        rsi3:  RSI.call(closes, period: 3)
      )
    end

    # Exponential Moving Average. Standard 1/(N+1) smoothing factor.
    module EMA
      module_function

      def call(closes, period:)
        return nil if closes.length < period

        multiplier = 2.0 / (period + 1)
        ema = closes.first(period).sum / period.to_f
        closes[period..].each { |c| ema = (c * multiplier) + (ema * (1 - multiplier)) }
        ema
      end
    end

    # Relative Strength Index using simple averaging (Cutler's RSI variant —
    # what TradingView shows by default for short periods is close enough).
    module RSI
      module_function

      def call(closes, period:)
        return nil if closes.length < period + 1

        gains  = 0.0
        losses = 0.0
        ((closes.length - period)...closes.length).each do |i|
          diff = closes[i] - closes[i - 1]
          diff.positive? ? gains += diff : losses -= diff
        end

        avg_gain = gains  / period
        avg_loss = losses / period
        return 100.0 if avg_loss.zero?

        rs = avg_gain / avg_loss
        100 - (100 / (1 + rs))
      end
    end

    # Volume-Weighted Average Price, anchored to the most recent ~6.5h of
    # candles (one US trading session). Approximate but correct for a
    # session-bias signal — not a precise replay of TradingView's anchored VWAP.
    module VWAP
      module_function

      def call(candles, timeframe:)
        minutes = MINUTES_PER_CANDLE.fetch(timeframe, 5)
        len     = [(SESSION_MINUTES.to_f / minutes).ceil, 1].max
        session = candles.last(len)
        return nil if session.empty?

        cum_tpv = session.sum { |c| ((c.high + c.low + c.close) / 3.0) * c.volume }
        cum_vol = session.sum(&:volume)
        cum_vol.zero? ? nil : cum_tpv / cum_vol
      end
    end
  end
end
