# frozen_string_literal: true

module TradingBot
  module Questrade
    # Account discovery + order placement.
    class Orders
      NoAccountError = Class.new(StandardError)

      def initialize(client:, market_data:, account_id: nil)
        @client      = client
        @market_data = market_data
        @account_id  = account_id
      end

      def account_id
        @account_id ||= discover_account_id
      end

      def place_market_order(ticker:, side:, quantity:)
        @client.post("/v1/accounts/#{account_id}/orders", {
          symbolId:       @market_data.symbol_id(ticker),
          quantity:       quantity,
          orderType:      'Market',
          timeInForce:    'Day',
          action:         side,
          primaryRoute:   'AUTO',
          secondaryRoute: 'AUTO'
        })
      end

      private

      def discover_account_id
        data = @client.get('/v1/accounts')
        accounts = data['accounts'] || []
        raise NoAccountError, 'No Questrade accounts found on this token.' if accounts.empty?

        accounts.first['number']
      end
    end
  end
end
