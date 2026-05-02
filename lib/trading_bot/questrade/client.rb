# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module TradingBot
  module Questrade
    # Thin authenticated HTTP client. Holds a Session + refreshes it via the
    # Authenticator when expired. Domain modules (MarketData, Orders) are
    # built on top.
    class Client
      ApiError = Class.new(StandardError)

      def initialize(authenticator:, refresh_token:)
        @authenticator = authenticator
        @refresh_token = refresh_token
        @session       = nil
      end

      def authenticate!
        @session = @authenticator.call(@refresh_token)
        @refresh_token = ENV.fetch('QUESTRADE_REFRESH_TOKEN') # Authenticator just rotated this
        @session
      end

      def session
        authenticate! if @session.nil? || @session.expired?
        @session
      end

      def get(path)
        request(Net::HTTP::Get, path)
      end

      def post(path, body)
        request(Net::HTTP::Post, path, body: body)
      end

      private

      def request(verb_class, path, body: nil)
        uri = URI("#{session.api_server}#{path}")
        req = verb_class.new(uri.request_uri)
        req['Authorization'] = session.authorization_header
        if body
          req['Content-Type'] = 'application/json'
          req.body = body.to_json
        end

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
        raise ApiError, "Questrade #{verb_class.name.split('::').last.upcase} #{path} failed (#{response.code}): #{response.body}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    end
  end
end
