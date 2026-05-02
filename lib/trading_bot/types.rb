# frozen_string_literal: true

module TradingBot
  # OHLCV bar from Questrade. `time` is a Time, not a unix int.
  Candle = Data.define(:time, :open, :high, :low, :close, :volume)

  # Snapshot of all indicator values at a point in time. Returned by
  # Indicators.call and consumed by SafetyCheck.
  IndicatorValues = Data.define(:price, :ema8, :vwap, :rsi3)

  # One pass/fail row in the safety check.
  Condition = Data.define(:label, :required, :actual, :pass) do
    def pass? = pass
  end

  # Output of SafetyCheck — what the bot decided and why.
  Decision = Data.define(:side, :all_pass, :conditions, :bias) do
    def block? = !all_pass
    def buy?   = side == 'Buy'
    def sell?  = side == 'Sell'
    def failed_conditions = conditions.reject(&:pass?)
  end
end
