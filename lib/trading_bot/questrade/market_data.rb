# frozen_string_literal: true

require 'uri'

module TradingBot
  module Questrade
    # Symbol lookup + candle fetching. Constructed with a Client.
    class MarketData
      INTERVAL_MAP = {
        '1m' => 'OneMinute',  '2m'  => 'TwoMinutes',  '3m'  => 'ThreeMinutes',
        '5m' => 'FiveMinutes','15m' => 'FifteenMinutes','30m' => 'HalfHour',
        '1H' => 'OneHour',    '4H'  => 'FourHours',    '1D'  => 'OneDay'
      }.freeze

      INTERVAL_MINUTES = TradingBot::Indicators::MINUTES_PER_CANDLE

      SymbolNotFound = Class.new(StandardError)

      def initialize(client:)
        @client = client
        @symbol_id_cache = {}
      end

      def symbol_id(ticker)
        @symbol_id_cache[ticker] ||= lookup_symbol_id(ticker)
      end

      def fetch_candles(ticker:, timeframe:, limit: 200)
        interval = INTERVAL_MAP.fetch(timeframe) { raise ArgumentError, "Unsupported timeframe: #{timeframe}" }
        minutes  = INTERVAL_MINUTES.fetch(timeframe)
        sid      = symbol_id(ticker)

        # Pull a 3x window so weekends/holidays don't leave us short.
        start_t = (Time.now - (minutes * 60 * limit * 3)).utc.iso8601
        end_t   = Time.now.utc.iso8601
        path    = "/v1/markets/candles/#{sid}" \
                  "?startTime=#{URI.encode_www_form_component(start_t)}" \
                  "&endTime=#{URI.encode_www_form_component(end_t)}" \
                  "&interval=#{interval}"

        data = @client.get(path)
        (data['candles'] || []).map { |c| build_candle(c) }
      rescue Client::ApiError => e
        # Questrade error code 1019 ("Symbol not found") on the candles
        # endpoint shows up even when the symbol search succeeded — usually
        # a delisted / migrated ticker that's still indexed. Surface as
        # SymbolNotFound so callers' existing rescue path handles it.
        raise SymbolNotFound, "Candles unavailable for #{ticker} (#{e.message[0, 120]})" if e.message.include?('Symbol not found')

        raise
      end

      private

      def lookup_symbol_id(ticker)
        data = @client.get("/v1/symbols/search?prefix=#{URI.encode_www_form_component(ticker)}")
        symbols = data['symbols'] || []
        raise SymbolNotFound, "No Questrade symbol found for #{ticker}" if symbols.empty?

        exact = symbols.find { |s| s['symbol'] == ticker }
        if exact.nil?
          candidates = symbols.map { |s| s['symbol'] }.join(', ')
          raise SymbolNotFound, "No exact match for #{ticker}. Candidates: #{candidates}"
        end
        exact['symbolId']
      end

      def build_candle(raw)
        Candle.new(
          time:   Time.parse(raw['start']),
          open:   raw['open'],
          high:   raw['high'],
          low:    raw['low'],
          close:  raw['close'],
          volume: raw['volume']
        )
      end
    end
  end
end
