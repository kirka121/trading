# frozen_string_literal: true

require 'dotenv/load'

# TradingBot — decision-only trading-signals tool, backed by Questrade for
# market data. The bot NEVER places orders — every run computes per-strategy
# Decisions and prints them as a table, with concrete entry/stop/target
# levels for finalized signals so the user can act manually.
#
# Pipeline:
#   1. Authenticate with Questrade (read-only — rotates single-use refresh token).
#   2. Fetch recent candles for each watchlist symbol on the strategy's timeframe.
#   3. Compute strategy-specific indicators.
#   4. Run SafetyCheck → Decision; ask the strategy for entry/stop/target levels.
#   5. Log + render via Output.
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
require_relative 'trading_bot/output'
require_relative 'trading_bot/tick_summary'
require_relative 'trading_bot/pipeline'
