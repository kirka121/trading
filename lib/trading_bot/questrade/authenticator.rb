# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module TradingBot
  module Questrade
    # Exchanges a refresh token for a Session, persisting the new refresh
    # token to .env atomically. Refresh tokens are SINGLE-USE — failing to
    # persist the new one locks you out and forces regeneration in the
    # Questrade UI. We write tmp + rename so a crash can't truncate .env.
    class Authenticator
      TOKEN_URL_LIVE     = 'https://login.questrade.com/oauth2/token'

      AuthError = Class.new(StandardError)

      def initialize(env_path: '.env')
        @env_path = env_path
      end

      def call(refresh_token)
        raise AuthError, 'refresh_token is empty' if refresh_token.to_s.empty?

        response = post_token_request(refresh_token)
        unless response.is_a?(Net::HTTPSuccess)
          raise AuthError, single_use_error_message(response)
        end

        data = JSON.parse(response.body)
        persist_refresh_token(data.fetch('refresh_token'))

        Session.new(
          access_token: data.fetch('access_token'),
          api_server:   data.fetch('api_server').chomp('/'),
          expires_at:   Time.now + data.fetch('expires_in')
        )
      end

      private

      def token_url
        TOKEN_URL_LIVE
      end

      def post_token_request(refresh_token)
        uri = URI("#{token_url}?grant_type=refresh_token&refresh_token=#{URI.encode_www_form_component(refresh_token)}")
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.post(uri.request_uri, '')
        end
      end

      def persist_refresh_token(new_token)
        lines = File.read(@env_path).split("\n", -1)
        idx = lines.find_index { |l| l.strip.start_with?('QUESTRADE_REFRESH_TOKEN=') }
        replacement = "QUESTRADE_REFRESH_TOKEN=#{new_token}"
        idx ? lines[idx] = replacement : lines << replacement

        tmp_path = "#{@env_path}.tmp"
        File.write(tmp_path, lines.join("\n"))
        File.rename(tmp_path, @env_path)
        ENV['QUESTRADE_REFRESH_TOKEN'] = new_token
      end

      def single_use_error_message(response)
        <<~MSG
          Questrade auth failed (#{response.code}): #{response.body}

          Refresh tokens are SINGLE-USE. If this token has been consumed,
          generate a new one: Questrade → API Centre → your app → Generate
          new token. Paste it into .env as QUESTRADE_REFRESH_TOKEN and
          re-run the bot.
        MSG
      end
    end
  end
end
