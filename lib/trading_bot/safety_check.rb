# frozen_string_literal: true

module TradingBot
  # Decides whether the strategy's entry conditions are met for the current
  # snapshot of indicator values. Pure function: no I/O, no logging.
  #
  #   SafetyCheck.call(IndicatorValues.new(...)) # => Decision
  module SafetyCheck
    MAX_VWAP_DISTANCE_PCT = 1.5
    BULLISH_RSI_THRESHOLD = 30
    BEARISH_RSI_THRESHOLD = 70

    module_function

    def call(values)
      return neutral_decision if values.vwap.nil? || values.rsi3.nil?

      if bullish?(values)
        bullish_decision(values)
      elsif bearish?(values)
        bearish_decision(values)
      else
        neutral_decision
      end
    end

    # ── private (module-level) ─────────────────────────────────────────────

    def bullish?(v) = v.price > v.vwap && v.price > v.ema8
    def bearish?(v) = v.price < v.vwap && v.price < v.ema8

    def bullish_decision(v)
      conditions = [
        Condition.new(
          label:    'Price above VWAP (buyers in control)',
          required: "> #{format('%.2f', v.vwap)}",
          actual:   format('%.2f', v.price),
          pass:     v.price > v.vwap
        ),
        Condition.new(
          label:    'Price above EMA(8) (uptrend confirmed)',
          required: "> #{format('%.2f', v.ema8)}",
          actual:   format('%.2f', v.price),
          pass:     v.price > v.ema8
        ),
        Condition.new(
          label:    "RSI(3) below #{BULLISH_RSI_THRESHOLD} (snap-back setup in uptrend)",
          required: "< #{BULLISH_RSI_THRESHOLD}",
          actual:   format('%.2f', v.rsi3),
          pass:     v.rsi3 < BULLISH_RSI_THRESHOLD
        ),
        vwap_distance_condition(v)
      ]
      Decision.new(side: 'Buy', all_pass: conditions.all?(&:pass?), conditions: conditions, bias: :bullish)
    end

    def bearish_decision(v)
      conditions = [
        Condition.new(
          label:    'Price below VWAP (sellers in control)',
          required: "< #{format('%.2f', v.vwap)}",
          actual:   format('%.2f', v.price),
          pass:     v.price < v.vwap
        ),
        Condition.new(
          label:    'Price below EMA(8) (downtrend confirmed)',
          required: "< #{format('%.2f', v.ema8)}",
          actual:   format('%.2f', v.price),
          pass:     v.price < v.ema8
        ),
        Condition.new(
          label:    "RSI(3) above #{BEARISH_RSI_THRESHOLD} (reversal setup in downtrend)",
          required: "> #{BEARISH_RSI_THRESHOLD}",
          actual:   format('%.2f', v.rsi3),
          pass:     v.rsi3 > BEARISH_RSI_THRESHOLD
        ),
        vwap_distance_condition(v)
      ]
      Decision.new(side: 'Sell', all_pass: conditions.all?(&:pass?), conditions: conditions, bias: :bearish)
    end

    def neutral_decision
      Decision.new(
        side:       nil,
        all_pass:   false,
        conditions: [
          Condition.new(label: 'Market bias', required: 'Bullish or bearish', actual: 'Neutral', pass: false)
        ],
        bias:       :neutral
      )
    end

    def vwap_distance_condition(v)
      dist_pct = ((v.price - v.vwap).abs / v.vwap) * 100
      Condition.new(
        label:    "Price within #{MAX_VWAP_DISTANCE_PCT}% of VWAP (not overextended)",
        required: "< #{MAX_VWAP_DISTANCE_PCT}%",
        actual:   "#{format('%.2f', dist_pct)}%",
        pass:     dist_pct < MAX_VWAP_DISTANCE_PCT
      )
    end
  end
end
