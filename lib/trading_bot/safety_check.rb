# frozen_string_literal: true

require_relative 'strategies/base'
require_relative 'strategies/vwap_rsi_ema'
require_relative 'strategies/gap_and_go_cameron'
require_relative 'strategies/abcd_aziz'
require_relative 'strategies/bull_flag_qullamaggie'
require_relative 'strategies/avwap_reclaim_shannon'
require_relative 'strategies/vcp_breakout_minervini'

module TradingBot
  # Dispatches an IndicatorValues snapshot to the right strategy module
  # based on the active strategy key in rules.json. Each registered module
  # implements `call(values) → Decision`.
  #
  #   SafetyCheck.call(values, strategy_key: 'vwap_rsi_ema')
  module SafetyCheck
    REGISTRY = {
      'vwap_rsi_ema'           => Strategies::VwapRsiEma,
      'gap_and_go_cameron'     => Strategies::GapAndGoCameron,
      'abcd_aziz'              => Strategies::AbcdAziz,
      'bull_flag_qullamaggie'  => Strategies::BullFlagQullamaggie,
      'avwap_reclaim_shannon'  => Strategies::AvwapReclaimShannon,
      'vcp_breakout_minervini' => Strategies::VcpBreakoutMinervini
    }.freeze

    UnknownStrategy = Class.new(StandardError)

    module_function

    def call(values, strategy_key: 'vwap_rsi_ema')
      strategy = REGISTRY.fetch(strategy_key) do
        raise UnknownStrategy,
              "Unknown strategy '#{strategy_key}'. Registered: #{REGISTRY.keys.join(', ')}"
      end
      strategy.call(values)
    end
  end
end
