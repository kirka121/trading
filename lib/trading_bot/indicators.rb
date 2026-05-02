# frozen_string_literal: true

module TradingBot
  # Stateless indicator calculators. Each is a service object exposing `.call`.
  # `Indicators.call` runs all of them and returns an IndicatorValues snapshot
  # — fields the input doesn't have enough history for come back as nil.
  module Indicators
    SESSION_MINUTES = 390 # US RTH (6.5h × 60min) — VWAP anchor window.

    MINUTES_PER_CANDLE = {
      '1m' => 1, '2m' => 2, '3m' => 3, '5m' => 5, '15m' => 15,
      '30m' => 30, '1H' => 60, '4H' => 240, '1D' => 1440
    }.freeze

    module_function

    def call(candles, timeframe:)
      closes = candles.map(&:close)
      IndicatorValues.new(
        price:       closes.last,
        ema8:        EMA.call(closes, period: 8),
        ema9:        EMA.call(closes, period: 9),
        ema10:       EMA.call(closes, period: 10),
        ema20:       EMA.call(closes, period: 20),
        sma50:       SMA.call(closes, period: 50),
        sma150:      SMA.call(closes, period: 150),
        sma200:      SMA.call(closes, period: 200),
        vwap:        VWAP.call(candles, timeframe: timeframe),
        rsi3:        RSI.call(closes, period: 3),
        atr14:       ATR.call(candles, period: 14),
        adr20_pct:   ADR.call(candles, period: 20),
        rel_volume:  RelativeVolume.call(candles, period: 50),
        prior_close: closes.size >= 2 ? closes[-2] : nil,
        gap_pct:     gap_percent(candles),
        candles:     candles
      )
    end

    # (today's open − yesterday's close) / yesterday's close × 100.
    # Only meaningful on daily candles or as a single-bar approximation.
    def gap_percent(candles)
      return nil if candles.length < 2

      prior = candles[-2].close
      open  = candles.last.open
      return nil if prior.nil? || prior.zero? || open.nil?

      ((open - prior) / prior) * 100.0
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

    # Simple Moving Average over the last `period` closes.
    module SMA
      module_function

      def call(closes, period:)
        return nil if closes.length < period

        closes.last(period).sum / period.to_f
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
        AnchoredVWAP.call(session)
      end
    end

    # Anchored VWAP starting from a specific candle index. Used by strategies
    # that need a non-session anchor (Brian Shannon-style reclaim setups).
    module AnchoredVWAP
      module_function

      def call(candles, anchor_idx: 0)
        return nil if candles.empty?

        slice = candles[anchor_idx..]
        return nil if slice.nil? || slice.empty?

        cum_tpv = slice.sum { |c| ((c.high + c.low + c.close) / 3.0) * c.volume }
        cum_vol = slice.sum(&:volume)
        cum_vol.zero? ? nil : cum_tpv / cum_vol
      end
    end

    # Wilder's True Range: max(high-low, |high - prevClose|, |low - prevClose|).
    # ATR is the simple average over the last `period` true ranges.
    module ATR
      module_function

      def call(candles, period:)
        return nil if candles.length < period + 1

        ranges = (candles.length - period...candles.length).map do |i|
          c, p = candles[i], candles[i - 1]
          [c.high - c.low, (c.high - p.close).abs, (c.low - p.close).abs].max
        end
        ranges.sum / period.to_f
      end
    end

    # Average Daily Range, as a percentage of last close. Qullamaggie-style
    # liquidity / asymmetry filter — wants ≥5% on his setups.
    module ADR
      module_function

      def call(candles, period:)
        return nil if candles.length < period

        recent = candles.last(period)
        ratios = recent.map { |c| c.low.zero? ? 0.0 : (c.high - c.low) / c.low }
        avg    = ratios.sum / period.to_f
        avg * 100.0
      end
    end

    # Latest bar's volume divided by the average of the prior `period` bars.
    # Returns 1.0 for "average", >1 for surge.
    module RelativeVolume
      module_function

      def call(candles, period:)
        return nil if candles.length < period + 1

        last_vol = candles.last.volume.to_f
        prior    = candles[-(period + 1)..-2]
        avg      = prior.sum(&:volume).to_f / period
        avg.zero? ? nil : last_vol / avg
      end
    end
  end
end
