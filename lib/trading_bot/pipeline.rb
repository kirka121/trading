# frozen_string_literal: true

require 'json'

module TradingBot
  # Orchestrates one decision cycle. All side effects (auth, HTTP, file I/O,
  # stdout) live here so the pieces it composes (Indicators, SafetyCheck) can
  # stay pure.
  class Pipeline
    def initialize(config:, logger: TradeLogger.new(csv_path: config.csv_path, json_path: config.decision_log_path))
      @config = config
      @logger = logger
      @client = build_client
      @market_data = Questrade::MarketData.new(client: @client)
      @orders      = Questrade::Orders.new(client: @client, market_data: @market_data, account_id: config.account_id)
    end

    def call
      print_header
      print_strategy_intro
      @logger.initialize_csv_if_missing

      decision_log = @logger.load_decision_log
      return unless within_trade_limits?(decision_log)

      @client.authenticate!

      @config.watchlist.each do |symbol|
        decision_log = @logger.load_decision_log
        unless within_trade_limits?(decision_log, announce_pass: false)
          puts "\nDaily trade cap reached — skipping remaining symbols."
          break
        end
        process_symbol(symbol, decision_log)
      end

      puts "\nDecision log saved → #{@config.decision_log_path}"
      puts '═══════════════════════════════════════════════════════════'
    end

    private

    def process_symbol(symbol, decision_log)
      puts "\n═══ #{symbol} ═══════════════════════════════════════════════"

      candles = fetch_candles_or_skip(symbol)
      return if candles.empty?

      values = Indicators.call(candles, timeframe: @config.timeframe)
      print_indicators(values)

      if values.vwap.nil? || values.rsi3.nil?
        puts "\n⚠️  Not enough data to calculate indicators for #{symbol}. Skipping."
        return
      end

      decision = SafetyCheck.call(values)
      print_safety_check(decision)

      entry = build_log_entry(symbol: symbol, values: values, decision: decision, decision_log: decision_log)
      execute_or_block(symbol: symbol, decision: decision, entry: entry)

      @logger.record(entry)
    end

    def build_client
      authenticator = Questrade::Authenticator.new(practice: @config.practice)
      Questrade::Client.new(authenticator: authenticator, refresh_token: @config.refresh_token)
    end

    def print_header
      puts '═══════════════════════════════════════════════════════════'
      puts '  Claude Trading Bot — Stocks via Questrade'
      puts "  #{Time.now.utc.iso8601}"
      puts "  Mode: #{@config.mode_label}"
      puts '═══════════════════════════════════════════════════════════'
    end

    def print_strategy_intro
      puts "\nStrategy: #{@config.strategy['name']} (#{@config.strategy_key})"
      puts "Watchlist: #{@config.watchlist.join(', ')} | Timeframe: #{@config.timeframe}"
    end

    def within_trade_limits?(decision_log, announce_pass: true)
      today_count = @logger.count_todays_orders(decision_log)
      if today_count >= @config.max_trades_per_day
        puts "\n── Trade Limits ─────────────────────────────────────────\n\n"
        puts "🚫 Max trades per day reached: #{today_count}/#{@config.max_trades_per_day}"
        return false
      end
      if announce_pass
        puts "\n── Trade Limits ─────────────────────────────────────────\n\n"
        puts "✅ Trades today: #{today_count}/#{@config.max_trades_per_day} — within limit"
        puts "✅ Trade size: $#{format('%.2f', @config.trade_size)} — max $#{format('%.2f', @config.max_trade_size)}"
      end
      true
    end

    def fetch_candles_or_skip(symbol)
      puts "\n── Fetching market data from Questrade ─────────────────\n\n"
      candles = @market_data.fetch_candles(ticker: symbol, timeframe: @config.timeframe, limit: 200)
      if candles.empty?
        puts "⚠️  No candles returned for #{symbol}. Market might be closed and outside data window."
      end
      candles
    rescue Questrade::MarketData::SymbolNotFound => e
      puts "⚠️  #{e.message} — skipping."
      []
    end

    def print_indicators(values)
      puts "  Current price: $#{format('%.2f', values.price)}"
      puts "  EMA(8):  $#{format('%.2f', values.ema8)}"
      puts "  VWAP:    #{values.vwap ? "$#{format('%.2f', values.vwap)}" : 'N/A'}"
      puts "  RSI(3):  #{values.rsi3 ? format('%.2f', values.rsi3) : 'N/A'}"
    end

    def print_safety_check(decision)
      puts "\n── Safety Check ─────────────────────────────────────────\n\n"
      puts "  Bias: #{decision.bias.to_s.upcase} — #{bias_explanation(decision)}\n\n"
      decision.conditions.each do |c|
        puts "  #{c.pass? ? '✅' : '🚫'} #{c.label}"
        puts "     Required: #{c.required} | Actual: #{c.actual}"
      end
    end

    def bias_explanation(decision)
      case decision.bias
      when :bullish then 'checking long entry conditions'
      when :bearish then 'checking short entry conditions'
      else 'no clear direction. No trade.'
      end
    end

    def build_log_entry(symbol:, values:, decision:, decision_log:)
      {
        'timestamp'     => Time.now.utc.iso8601,
        'symbol'        => symbol,
        'timeframe'     => @config.timeframe,
        'price'         => values.price,
        'indicators'    => { 'ema8' => values.ema8, 'vwap' => values.vwap, 'rsi3' => values.rsi3 },
        'conditions'    => decision.conditions.map(&:to_h).map { |h| h.transform_keys(&:to_s) },
        'all_pass'      => decision.all_pass,
        'side'          => decision.side,
        'bias'          => decision.bias.to_s,
        'trade_size'    => @config.trade_size,
        'quantity'      => quantity_for(values.price),
        'order_placed'  => false,
        'order_id'      => nil,
        'paper_trading' => @config.paper_trading,
        'practice'      => @config.practice,
        'limits' => {
          'max_trade_size'     => @config.max_trade_size,
          'max_trades_per_day' => @config.max_trades_per_day,
          'trades_today'       => @logger.count_todays_orders(decision_log)
        }
      }
    end

    def quantity_for(price)
      (@config.trade_size / price).floor
    end

    def execute_or_block(symbol:, decision:, entry:)
      puts "\n── Decision ─────────────────────────────────────────────\n\n"

      if decision.block?
        announce_block(decision)
        return
      end

      if entry['quantity'] < 1
        announce_quantity_too_small(entry)
        return
      end

      puts '✅ ALL CONDITIONS MET'
      if @config.paper_trading
        record_paper_fill(symbol: symbol, decision: decision, entry: entry)
      elsif !MarketClock.open?
        entry['error'] = 'Market closed'
        puts '🚫 US market is closed. Order not sent.'
      else
        send_real_order(symbol: symbol, decision: decision, entry: entry)
      end
    end

    def announce_block(decision)
      puts '🚫 TRADE BLOCKED'
      puts '   Failed conditions:'
      decision.failed_conditions.each { |c| puts "   - #{c.label}" }
    end

    def announce_quantity_too_small(entry)
      puts "🚫 Computed quantity is 0 shares (price $#{format('%.2f', entry['price'])} > trade size $#{format('%.2f', entry['trade_size'])})."
      entry['all_pass'] = false
      entry['conditions'] << { 'label' => 'Quantity ≥ 1', 'required' => '≥ 1 share', 'actual' => '0', 'pass' => false }
    end

    def record_paper_fill(symbol:, decision:, entry:)
      qty = entry['quantity']
      px  = entry['price']
      puts "\n📋 PAPER — would #{decision.side.upcase} #{qty} shares of #{symbol} @ ~$#{format('%.2f', px)} (notional ~$#{format('%.2f', qty * px)})"
      puts '   (Set PAPER_TRADING=false to send the order to your Questrade practice account)'
      entry['order_placed'] = true
      entry['order_id']     = "PAPER-#{(Time.now.to_f * 1000).to_i}"
    end

    def send_real_order(symbol:, decision:, entry:)
      env_label = @config.practice ? 'PRACTICE' : 'LIVE'
      puts "\n🟡 SENDING #{decision.side.upcase} order — #{entry['quantity']} shares #{symbol} (Questrade #{env_label})"
      response = @orders.place_market_order(ticker: symbol, side: decision.side, quantity: entry['quantity'])
      order_id = response.dig('orders', 0, 'id') || response['orderId'] || response.to_json
      entry['order_placed'] = true
      entry['order_id']     = order_id.to_s
      puts "✅ ORDER PLACED — #{order_id}"
    rescue StandardError => e
      puts "❌ ORDER FAILED — #{e.message}"
      entry['error'] = e.message
    end
  end
end
