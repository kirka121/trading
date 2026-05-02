# frozen_string_literal: true

module TradingBot
  module Strategies
    # Helpers shared by every per-strategy SafetyCheck. Modules `extend Base`
    # to pick up the `condition` builders + the `neutral_decision` /
    # `missing_data_decision` factories.
    module Base
      # Build a Condition with both label/required/actual filled in.
      def condition(label:, required:, actual:, pass:)
        Condition.new(label: label, required: required, actual: actual, pass: pass)
      end

      def fmt(value, decimals: 2)
        return '—' if value.nil?

        format("%.#{decimals}f", value)
      end

      # Returns a "no clear bias" Decision.
      def neutral_decision(reason: 'No setup')
        Decision.new(
          side:       nil,
          all_pass:   false,
          conditions: [Condition.new(label: 'Market bias', required: 'Bullish or bearish', actual: reason, pass: false)],
          bias:       :neutral
        )
      end

      # Returned when the strategy needs inputs the bot can't (currently)
      # supply — e.g. pre-market candles, IBD relative-strength rating, share
      # float. Surfacing these as failed Conditions makes the bot skip with a
      # clear reason rather than silently trading on degraded data.
      def missing_data_decision(missing_fields)
        conds = Array(missing_fields).map do |field|
          Condition.new(label: "Required input: #{field}", required: 'present', actual: 'unavailable', pass: false)
        end
        Decision.new(side: nil, all_pass: false, conditions: conds, bias: :neutral)
      end

      # Convenience: yields side / all_pass / conditions / bias to a final
      # Decision constructor — keeps the per-strategy code readable.
      def decision(side:, conditions:, bias:)
        Decision.new(side: side, all_pass: conditions.all?(&:pass?), conditions: conditions, bias: bias)
      end
    end
  end
end
