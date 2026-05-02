# frozen_string_literal: true

require 'dotenv/load'

# TradingBot — automated stock-trading pipeline backed by Questrade.
#
# Pipeline:
#   1. Authenticate with Questrade (rotates single-use refresh token).
#   2. Fetch recent candles for the configured symbol/timeframe.
#   3. Compute EMA(8), VWAP, RSI(3).
#   4. Run SafetyCheck → Decision.
#   5. Log decision + (optionally) place order on practice or live account.
module TradingBot
end

require_relative 'trading_bot/types'
require_relative 'trading_bot/config'
require_relative 'trading_bot/market_clock'
require_relative 'trading_bot/indicators'
require_relative 'trading_bot/safety_check'
require_relative 'trading_bot/trade_logger'
require_relative 'trading_bot/questrade/session'
require_relative 'trading_bot/questrade/authenticator'
require_relative 'trading_bot/questrade/client'
require_relative 'trading_bot/questrade/market_data'
require_relative 'trading_bot/questrade/orders'
require_relative 'trading_bot/pipeline'
