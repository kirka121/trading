# frozen_string_literal: true

require_relative 'cdp/target_finder'
require_relative 'cdp/client'

module MCP
  module TradingView
    # Process-wide singleton holding the live CDP connection plus the helpers
    # every tool reaches for: evaluate JS in the chart page, dispatch keyboard
    # events, look up the active target.
    #
    # Tools never instantiate this — they call Session.current. Connection is
    # lazy and self-healing: if the CDP socket dies between requests, the
    # next call reconnects to whatever chart target is currently active.
    class Session
      MAX_RETRIES = 3
      BASE_BACKOFF = 0.5
      KEY_MOD_META  = 4 # Cmd / ⌘
      KEY_MOD_CTRL  = 2

      # macOS AppleScript modifier names. CDP synthetic key events don't
      # reach Electron's native menu — Cmd+T (new tab), Cmd+W (close tab),
      # etc. are eaten by the menu before the renderer ever sees them.
      # For those we shell out to `osascript` which goes through the OS
      # input pipeline.
      AS_MODIFIERS = { cmd: 'command down', ctrl: 'control down', alt: 'option down', shift: 'shift down' }.freeze
      AS_SPECIAL_KEY_CODES = { 'Enter' => 36, 'Return' => 36, 'Escape' => 53, 'Tab' => 48, 'Space' => 49 }.freeze

      class << self
        def current
          @current ||= new
        end

        def reset!
          @current&.disconnect
          @current = nil
        end
      end

      def initialize(host: CDP::TargetFinder::DEFAULT_HOST, port: CDP::TargetFinder::DEFAULT_PORT)
        @host = host
        @port = port
      end

      attr_reader :host, :port

      def evaluate(expression, await_promise: false, timeout: CDP::Client::DEFAULT_TIMEOUT)
        with_client { |c| c.evaluate(expression, await_promise: await_promise, timeout: timeout) }
      end

      def evaluate_async(expression, timeout: CDP::Client::DEFAULT_TIMEOUT)
        evaluate(expression, await_promise: true, timeout: timeout)
      end

      # Send a CDP Input.dispatchKeyEvent. `mod_key` is :cmd (mac) or :ctrl.
      # We hand-roll the modifier flag so callers don't have to remember CDP's
      # bitfield (1=alt 2=ctrl 4=meta 8=shift).
      def dispatch_modifier_keystroke(key:, code:, virtual_key:, mod_key: default_mod_key)
        modifier = mod_key == :cmd ? KEY_MOD_META : KEY_MOD_CTRL
        with_client do |c|
          c.send_command(
            'Input.dispatchKeyEvent',
            type: 'keyDown', modifiers: modifier, key: key, code: code, windowsVirtualKeyCode: virtual_key
          )
          c.send_command('Input.dispatchKeyEvent', type: 'keyUp', key: key, code: code)
        end
      end

      # Send a single (no-modifier) key down/up — used for Enter, Escape,
      # arrow keys, etc. that drive UI dialogs.
      def dispatch_keystroke(key:, code:, virtual_key:)
        with_client do |c|
          c.send_command('Input.dispatchKeyEvent', type: 'keyDown', key: key, code: code, windowsVirtualKeyCode: virtual_key)
          c.send_command('Input.dispatchKeyEvent', type: 'keyUp',   key: key, code: code)
        end
      end

      # Type literal text into whatever input has focus. CDP exposes this
      # as Input.insertText — preferable to synthesising a keyDown per char
      # because it preserves IME/composition behaviour on TV's React inputs.
      def insert_text(text)
        with_client { |c| c.send_command('Input.insertText', text: text) }
      end

      # Dispatch a keystroke at the OS level via osascript / System Events.
      # Required for Electron app-menu shortcuts (Cmd+T, Cmd+W) that CDP's
      # synthetic input pipeline cannot reach. macOS only — on other
      # platforms this raises so callers can choose a different fallback.
      #
      #   session.os_keystroke(key: 't',     modifiers: [:cmd])
      #   session.os_keystroke(key: 'Enter')
      def os_keystroke(key:, modifiers: [])
        raise NotImplementedError, 'os_keystroke is macOS-only' unless RUBY_PLATFORM.match?(/darwin/)

        modifier_clause = if modifiers.empty?
                           ''
                         else
                           names = modifiers.map { |m| AS_MODIFIERS.fetch(m) { raise ArgumentError, "Unknown modifier: #{m.inspect}" } }
                           " using {#{names.join(', ')}}"
                         end

        action = if (code = AS_SPECIAL_KEY_CODES[key])
                  "key code #{code}#{modifier_clause}"
                else
                  %(keystroke "#{key.gsub('"', '\\"')}"#{modifier_clause})
                end

        script = <<~APPLESCRIPT
          tell application "TradingView" to activate
          delay 0.05
          tell application "System Events" to #{action}
        APPLESCRIPT

        ok = system('osascript', '-e', script, out: File::NULL, err: File::NULL)
        raise "osascript failed dispatching key=#{key.inspect} modifiers=#{modifiers}" unless ok
      end

      # Native target_id for the page we're currently attached to.
      def target_id
        connect! unless @target
        @target['id']
      end

      def disconnect
        @client&.close
      ensure
        @client = nil
        @target = nil
      end

      def default_mod_key
        RUBY_PLATFORM.match?(/darwin/) ? :cmd : :ctrl
      end

      private

      # Yields a live CDP client. Reconnects on dropped sockets or stale
      # targets. Retries with exponential backoff to ride through TV restarts.
      def with_client
        attempts = 0
        begin
          connect! unless connected?
          yield @client
        rescue CDP::Client::ConnectionLost, CDP::Client::CommandFailed, CDP::TargetFinder::NotFound,
               Errno::ECONNREFUSED, Errno::EPIPE => e
          attempts += 1
          disconnect
          raise e if attempts > MAX_RETRIES

          sleep(BASE_BACKOFF * (2**(attempts - 1)))
          retry
        end
      end

      def connected?
        @client && @client.alive?
      end

      def connect!
        @target = CDP::TargetFinder.find(host: @host, port: @port)
        @client = CDP::Client.connect(target_id: @target['id'], host: @host, port: @port)
      end
    end
  end
end
