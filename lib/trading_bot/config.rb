# frozen_string_literal: true

require 'json'

module TradingBot
  # Frozen, validated config object built from ENV. Construct via Config.from_env.
  Config = Data.define(
    :watchlist,
    :timeframe,
    :portfolio_value,
    :max_trade_size,
    :max_trades_per_day,
    :paper_trading,
    :practice,
    :refresh_token,
    :account_id,
    :rules_path,
    :strategy_key,
    :strategy,
    :csv_path,
    :decision_log_path
  ) do
    SUPPORTED_TIMEFRAMES = %w[1m 2m 3m 5m 15m 30m 1H 4H 1D].freeze

    def self.from_env
      rules_path   = 'rules.json'
      rules        = JSON.parse(File.read(rules_path))
      strategies   = rules['strategies'] || {}
      strategy_key = ENV['ACTIVE_STRATEGY'].to_s.strip
      strategy_key = rules['active_strategy'].to_s if strategy_key.empty?
      strategy     = strategies[strategy_key]

      if strategy.nil?
        available = strategies.keys.join(', ')
        raise ArgumentError,
              "Active strategy #{strategy_key.inspect} not found in rules.json. Available: #{available}"
      end

      watchlist  = Array(rules['watchlist']).map { |s| s.to_s.strip }.reject(&:empty?)
      default_tf = strategy['default_timeframe'] || '5m'

      new(
        watchlist:          watchlist,
        timeframe:          ENV.fetch('TIMEFRAME', default_tf),
        portfolio_value:    ENV.fetch('PORTFOLIO_VALUE_USD', '10000').to_f,
        max_trade_size:     ENV.fetch('MAX_TRADE_SIZE_USD',  '500').to_f,
        max_trades_per_day: ENV.fetch('MAX_TRADES_PER_DAY',  '3').to_i,
        paper_trading:      ENV['PAPER_TRADING']      != 'false',
        practice:           ENV['QUESTRADE_PRACTICE'] != 'false',
        refresh_token:      ENV['QUESTRADE_REFRESH_TOKEN'].to_s,
        account_id:         ENV['QUESTRADE_ACCOUNT_ID'].to_s.empty? ? nil : ENV['QUESTRADE_ACCOUNT_ID'],
        rules_path:         rules_path,
        strategy_key:       strategy_key,
        strategy:           strategy,
        csv_path:           'trades.csv',
        decision_log_path:  'safety-check-log.json'
      ).tap(&:validate!)
    end

    def validate!
      raise ArgumentError, "QUESTRADE_REFRESH_TOKEN missing in .env" if refresh_token.empty?
      raise ArgumentError, "rules.json watchlist is empty — add at least one symbol" if watchlist.empty?
      unless SUPPORTED_TIMEFRAMES.include?(timeframe)
        raise ArgumentError, "Unsupported timeframe #{timeframe.inspect}. Supported: #{SUPPORTED_TIMEFRAMES.join(', ')}"
      end
      raise ArgumentError, "PORTFOLIO_VALUE_USD must be > 0" unless portfolio_value.positive?
      raise ArgumentError, "MAX_TRADE_SIZE_USD must be > 0"  unless max_trade_size.positive?
      raise ArgumentError, "MAX_TRADES_PER_DAY must be > 0"  unless max_trades_per_day.positive?
    end

    def trade_size
      [portfolio_value * 0.01, max_trade_size].min
    end

    # Timeframe expressed in seconds. Used by `bin/bot` to sleep between
    # iterations so the bot re-triggers in step with the strategy's candles.
    def refresh_seconds
      case timeframe
      when /\A(\d+)m\z/ then Regexp.last_match(1).to_i * 60
      when /\A(\d+)H\z/ then Regexp.last_match(1).to_i * 3600
      when /\A(\d+)D\z/ then Regexp.last_match(1).to_i * 86_400
      end
    end

    def mode_label
      return '📋 PAPER'    if paper_trading
      return '🟡 PRACTICE' if practice
      '🔴 LIVE'
    end
  end
end
