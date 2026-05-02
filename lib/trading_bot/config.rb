# frozen_string_literal: true

require 'json'

module TradingBot
  # Frozen, validated config object built from rules.json + ENV. Construct via
  # Config.from_env.
  #
  # The bot is a *decision-only* tool — it never places orders. So this Config
  # carries no paper/practice/live mode, no account ID, and no order-related
  # plumbing. The only Questrade dependency is `refresh_token`, used purely to
  # fetch market data.
  Config = Data.define(
    :watchlist,
    :portfolio_value,
    :max_trade_size,
    :max_trades_per_day,
    :refresh_token,
    :rules_path,
    :csv_path,
    :decision_log_path,
    :strategies
  ) do
    SUPPORTED_TIMEFRAMES = %w[1m 2m 3m 5m 15m 30m 1H 4H 1D].freeze

    # `strategy_keys`: optional override. When set (e.g. via `bin/bot
    # --strategies vwap_rsi_ema,abcd_aziz`), Config ignores rules.json's
    # `active_strategy` and uses ONLY the supplied keys. Lets the user
    # pin a subset for ad-hoc runs without editing rules.json.
    def self.from_env(strategy_keys: nil)
      rules_path = 'rules.json'
      rules      = JSON.parse(File.read(rules_path))
      strategies = build_strategies(rules, override_keys: strategy_keys)

      new(
        watchlist:          parse_watchlist(rules),
        portfolio_value:    ENV.fetch('PORTFOLIO_VALUE_USD', '10000').to_f,
        max_trade_size:     ENV.fetch('MAX_TRADE_SIZE_USD',  '500').to_f,
        max_trades_per_day: ENV.fetch('MAX_TRADES_PER_DAY',  '3').to_i,
        refresh_token:      ENV['QUESTRADE_REFRESH_TOKEN'].to_s,
        rules_path:         rules_path,
        csv_path:           'trades.csv',
        decision_log_path:  'safety-check-log.json',
        strategies:         strategies
      ).tap(&:validate!)
    end

    # Resolves the set of active strategies. Order of precedence:
    #   1. `override_keys` (CLI `--strategies` flag) — used as-is.
    #   2. `rules.json`'s `active_strategy: "all"` — every registered key.
    #   3. `rules.json`'s `active_strategy: "<key>"` — exactly that key.
    # Raises with a clear message if any requested key isn't registered.
    def self.build_strategies(rules, override_keys: nil)
      registry = rules['strategies'] || {}

      keys = if override_keys && !override_keys.empty?
               override_keys
             else
               active = rules['active_strategy'].to_s
               raise ArgumentError, 'rules.json: active_strategy is empty' if active.empty?

               active == 'all' ? registry.keys : [active]
             end

      missing = keys.reject { |k| registry.key?(k) }
      unless missing.empty?
        source = override_keys ? '--strategies flag' : 'active_strategy'
        raise ArgumentError,
              "Unknown strategy key(s) #{missing.inspect} in #{source}. Registered: #{registry.keys.join(', ')}"
      end

      keys.map { |key| build_strategy_spec(key, registry[key]) }
    end

    def self.build_strategy_spec(key, rules_for_key)
      tf = (rules_for_key['default_timeframe'] || '5m').to_s
      StrategySpec.new(
        key:                key,
        name:               rules_for_key['name'] || key,
        timeframe:          tf,
        refresh_seconds:    timeframe_to_seconds(tf),
        rules:              rules_for_key,
        applicable_symbols: parse_applicable_symbols(rules_for_key['applicable_symbols'])
      )
    end

    # Optional whitelist; nil means "apply to the whole watchlist". Empty
    # array also collapses to nil so an `[]` in rules.json doesn't silently
    # filter every symbol away.
    def self.parse_applicable_symbols(raw)
      return nil if raw.nil?
      return nil unless raw.is_a?(Array)

      cleaned = raw.map(&:to_s).map(&:strip).reject(&:empty?)
      cleaned.empty? ? nil : cleaned
    end

    # Parses tokens like 5m / 15m / 1H / 4H / 1D into seconds.
    def self.timeframe_to_seconds(tf)
      case tf
      when /\A(\d+)m\z/ then Regexp.last_match(1).to_i * 60
      when /\A(\d+)H\z/ then Regexp.last_match(1).to_i * 3600
      when /\A(\d+)D\z/ then Regexp.last_match(1).to_i * 86_400
      end
    end

    # Watchlist entries can be either an object {"questrade": "...", "tv": "..."}
    # or a bare string (in which case both fields share the same value —
    # backwards-compat with the old single-symbol form).
    def self.parse_watchlist(rules)
      Array(rules['watchlist']).filter_map do |entry|
        case entry
        when Hash
          q  = entry['questrade'].to_s.strip
          tv = (entry['tv'].to_s.empty? ? entry['questrade'] : entry['tv']).to_s.strip
          q.empty? ? nil : WatchlistEntry.new(questrade: q, tv: tv)
        when String
          q = entry.strip
          q.empty? ? nil : WatchlistEntry.new(questrade: q, tv: q)
        else
          raise ArgumentError, "Unsupported watchlist entry: #{entry.inspect}"
        end
      end
    end

    def validate!
      raise ArgumentError, "QUESTRADE_REFRESH_TOKEN missing in .env" if refresh_token.empty?
      raise ArgumentError, "rules.json watchlist is empty — add at least one symbol" if watchlist.empty?
      raise ArgumentError, "rules.json: no active strategies resolved" if strategies.empty?

      strategies.each do |spec|
        unless SUPPORTED_TIMEFRAMES.include?(spec.timeframe)
          raise ArgumentError,
                "Strategy #{spec.key.inspect}: unsupported timeframe #{spec.timeframe.inspect}. Supported: #{SUPPORTED_TIMEFRAMES.join(', ')}"
        end
        if spec.refresh_seconds.nil?
          raise ArgumentError,
                "Strategy #{spec.key.inspect}: cannot derive refresh interval from timeframe #{spec.timeframe.inspect}"
        end
      end

      raise ArgumentError, "PORTFOLIO_VALUE_USD must be > 0" unless portfolio_value.positive?
      raise ArgumentError, "MAX_TRADE_SIZE_USD must be > 0"  unless max_trade_size.positive?
      raise ArgumentError, "MAX_TRADES_PER_DAY must be > 0"  unless max_trades_per_day.positive?
    end

    # Suggested per-trade notional: 1% of the portfolio capped at MAX_TRADE_SIZE.
    # Informational only — the bot never executes against this.
    def trade_size
      [portfolio_value * 0.01, max_trade_size].min
    end
  end
end
