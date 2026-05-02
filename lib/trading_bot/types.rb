# frozen_string_literal: true

module TradingBot
  # OHLCV bar from Questrade. `time` is a Time, not a unix int.
  Candle = Data.define(:time, :open, :high, :low, :close, :volume)

  # One watchlist entry. `questrade` is the symbol Questrade's API expects
  # (e.g. "VSP.TO" for the Toronto-listed Vanguard S&P500 hedged ETF);
  # `tv` is the corresponding TradingView ticker (e.g. "VSP"). Most names
  # are identical between the two; pairs only diverge for cross-listed or
  # exchange-prefixed symbols.
  WatchlistEntry = Data.define(:questrade, :tv) do
    # Display label for table rows / log entries — TV form is the one most
    # users recognise (it's what they see on the chart).
    def label = tv
  end

  # One strategy's run-time spec — derived from rules.json. Multiple
  # StrategySpecs coexist in Config when rules.json's active_strategy is
  # "all". Each has its own timeframe, so the bot loop schedules them
  # independently.
  #
  # `applicable_symbols`: optional array of TV-or-Questrade tickers that
  # narrows the strategy down to a subset of the global watchlist. nil =
  # apply to every watchlist symbol (default).
  StrategySpec = Data.define(:key, :name, :timeframe, :refresh_seconds, :rules, :applicable_symbols)

  # Snapshot of all indicator values + raw candles at a point in time.
  # Returned by Indicators.call and consumed by per-strategy SafetyChecks.
  IndicatorValues = Data.define(
    :price,
    :ema8, :ema9, :ema10, :ema20,
    :sma50, :sma150, :sma200,
    :vwap, :rsi3,
    :atr14, :adr20_pct, :rel_volume,
    :prior_close, :gap_pct,
    :candles
  )

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
