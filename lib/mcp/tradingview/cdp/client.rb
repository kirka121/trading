# frozen_string_literal: true

require 'json'
require 'socket'
require 'websocket/driver'

module MCP
  module TradingView
    module CDP
      # Synchronous Chrome DevTools Protocol client over a single WebSocket
      # connection. Each `send_command` writes a JSON-RPC frame, then blocks
      # reading the socket until a response with the matching id arrives.
      #
      # CDP also pushes domain events (Runtime.consoleAPICalled, Page.*) — we
      # silently drop those; this client only cares about command responses.
      class Client
        DEFAULT_TIMEOUT = 30
        READ_BUFFER     = 64 * 1024

        class Error < StandardError; end
        class ConnectionLost < Error; end
        class CommandFailed < Error
          attr_reader :code, :method_name

          def initialize(method_name, code, message)
            super("CDP #{method_name} failed (#{code}): #{message}")
            @method_name = method_name
            @code = code
          end
        end

        # Adapter that satisfies the duck-type WebSocket::Driver wants from
        # its IO: #url (target ws:// URL for the handshake) and #write
        # (bytes pushed to the wire). We wrap the raw TCP socket so the
        # driver's reads/writes funnel through one place.
        class SocketAdapter
          attr_reader :url

          def initialize(socket, url)
            @socket = socket
            @url    = url
          end

          def write(data) = @socket.write(data)
        end
        private_constant :SocketAdapter

        def self.connect(target_id:, host: TargetFinder::DEFAULT_HOST, port: TargetFinder::DEFAULT_PORT)
          new(target_id: target_id, host: host, port: port).tap(&:open!)
        end

        def initialize(target_id:, host:, port:)
          @target_id = target_id
          @host = host
          @port = port
          @next_id = 0
          @pending = {}
          @open = false
          @closed = false
        end

        def open!
          @socket = TCPSocket.new(@host, @port)
          url     = "ws://#{@host}:#{@port}/devtools/page/#{@target_id}"
          @driver = WebSocket::Driver.client(SocketAdapter.new(@socket, url))

          @driver.on(:open)    { @open = true }
          @driver.on(:close)   { @closed = true }
          @driver.on(:message) { |evt| handle_message(evt.data) }

          @driver.start
          pump_until { @open || @closed }
          raise ConnectionLost, "WebSocket handshake failed for target #{@target_id}" unless @open

          # Enable the domains every tool relies on.
          send_command('Runtime.enable')
          send_command('Page.enable')
          send_command('DOM.enable')
          self
        end

        # Send a CDP command and block for its response. Returns the result
        # hash (already a plain Ruby value) or raises CommandFailed.
        def send_command(method, params = {}, timeout: DEFAULT_TIMEOUT)
          ensure_open!
          id = (@next_id += 1)
          @pending[id] = nil
          frame = JSON.generate(id: id, method: method, params: params)
          @driver.text(frame)

          deadline = monotonic_now + timeout
          pump_until(deadline: deadline) { @pending[id] || @closed }

          response = @pending.delete(id)
          raise ConnectionLost, "Connection closed while awaiting #{method}" if response.nil?
          raise CommandFailed.new(method, response['error']['code'], response['error']['message']) if response['error']

          response['result']
        end

        # Convenience: Runtime.evaluate with returnByValue. Returns the unwrapped
        # value, or raises CommandFailed with the JS exception details.
        def evaluate(expression, await_promise: false, timeout: DEFAULT_TIMEOUT)
          result = send_command(
            'Runtime.evaluate',
            { expression: expression, returnByValue: true, awaitPromise: await_promise },
            timeout: timeout
          )
          if (details = result['exceptionDetails'])
            msg = details.dig('exception', 'description') || details['text'] || 'Unknown JS evaluation error'
            raise CommandFailed.new('Runtime.evaluate', -32000, msg)
          end
          result.dig('result', 'value')
        end

        def evaluate_async(expression, timeout: DEFAULT_TIMEOUT)
          evaluate(expression, await_promise: true, timeout: timeout)
        end

        # Liveness probe — cheap eval that confirms the page is still attached.
        def alive?
          evaluate('1') == 1
        rescue StandardError
          false
        end

        def close
          @driver&.close
          @socket&.close
        rescue StandardError
          # nothing to do — we're shutting down
        ensure
          @closed = true
          @open = false
        end

        private

        def handle_message(raw)
          message = JSON.parse(raw)
          id = message['id']
          return unless id # Drop CDP domain events.

          @pending[id] = message if @pending.key?(id)
        end

        # Reads from the socket and feeds the websocket driver until the block
        # returns truthy, the connection closes, or the deadline elapses.
        def pump_until(deadline: nil)
          until yield
            timeout = deadline ? deadline - monotonic_now : nil
            raise CommandFailed.new('CDP wait', -32001, 'Timed out waiting for response') if timeout&.negative?

            ready = IO.select([@socket], nil, nil, timeout)
            unless ready
              raise CommandFailed.new('CDP wait', -32001, 'Timed out waiting for response') if deadline

              next
            end

            chunk = read_chunk
            break if chunk.nil?

            @driver.parse(chunk)
          end
        end

        def read_chunk
          @socket.read_nonblock(READ_BUFFER)
        rescue IO::WaitReadable
          ''
        rescue EOFError, Errno::ECONNRESET
          @closed = true
          nil
        end

        def ensure_open!
          raise ConnectionLost, 'CDP connection is not open' unless @open && !@closed
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
