# frozen_string_literal: true

module TradingBot
  module Questrade
    # An authenticated session — the result of consuming a refresh token.
    # `api_server` is the URL prefix Questrade returns for subsequent calls
    # (different per token; do not hardcode).
    Session = Data.define(:access_token, :api_server, :expires_at) do
      EXPIRY_BUFFER_SECONDS = 30

      def expired?(now: Time.now)
        now >= expires_at - EXPIRY_BUFFER_SECONDS
      end

      def authorization_header
        "Bearer #{access_token}"
      end
    end
  end
end
