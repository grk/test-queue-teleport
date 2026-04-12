# frozen_string_literal: true

require "socket"
require "securerandom"

module TestQueueTeleport
  class Connect
    def initialize(command:, url:, api_key:, run_id:, encryption_key: nil)
      @command = command
      @url = url
      @api_key = api_key
      @run_id = run_id
      @encryption_key = encryption_key
    end

    def run
      @tcp_server = TCPServer.new("127.0.0.1", 0)
      relay_port = @tcp_server.addr[1]

      ws_url = "#{@url}?role=worker&run_id=#{@run_id}"
      $stderr.puts "[tq-teleport connect] Connecting as worker..."
      @ws = WsClient.new(ws_url, api_key: @api_key)
      $stderr.puts "[tq-teleport connect] Connected. Relay: 127.0.0.1:#{relay_port}"

      @in_flight = Mutex.new
      @in_flight_count = 0
      @in_flight_zero = ConditionVariable.new

      @bridge_thread = Thread.new { bridge_loop }

      env = {
        "TEST_QUEUE_RELAY" => "127.0.0.1:#{relay_port}",
        "TEST_QUEUE_RELAY_TOKEN" => @run_id
      }
      pid = Process.spawn(env, *@command)

      setup_signal_forwarding(pid)

      _, status = Process.waitpid2(pid)

      # Wait for in-flight requests (WORKER results) to finish sending
      @in_flight.synchronize do
        unless @in_flight_count == 0
          Log.debug "[tq-teleport connect] Waiting for #{@in_flight_count} in-flight requests..."
          @in_flight_zero.wait(@in_flight, 10)
        end
      end

      cleanup

      status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
    end

    private

    def bridge_loop
      loop do
        if @ws.closed?
          break if @ws.explicitly_closed?
          attempt_reconnect or break
        end

        ready = IO.select([@tcp_server], nil, nil, 1)
        next unless ready

        client = @tcp_server.accept
        @in_flight.synchronize { @in_flight_count += 1 }
        Thread.new(client) do |c|
          handle_connection(c)
        ensure
          @in_flight.synchronize do
            @in_flight_count -= 1
            @in_flight_zero.signal if @in_flight_count == 0
          end
        end
      rescue IOError
        break
      end
    end

    def handle_connection(client)
      data = +""
      loop do
        chunk = client.readpartial(65536)
        data << chunk
        ready = IO.select([client], nil, nil, 0.1)
        break unless ready
      rescue EOFError
        break
      end

      Log.debug "[tq-teleport connect] TCP recv #{data.bytesize} bytes"

      response = send_with_retry(data)

      # No usable response — close TCP so test-queue sees connection error
      unless response && response["data"]
        Log.debug "[tq-teleport connect] No response, closing TCP connection"
        client.close
        return
      end

      response_data = response["data"]
      response_data = Cipher.decrypt(@encryption_key, response_data) if @encryption_key
      response_bytes = response_data.unpack1("m0")
      Log.debug "[tq-teleport connect] Response #{response_bytes.bytesize} bytes"
      client.write(response_bytes) unless response_bytes.empty?

      client.close
    rescue StandardError => e
      $stderr.puts "[tq-teleport connect] Bridge error: #{e.message}"
      client&.close rescue nil
    end

    def send_with_retry(data)
      encoded_data = [data].pack("m0")
      encoded_data = Cipher.encrypt(@encryption_key, encoded_data) if @encryption_key

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30

      loop do
        conn_id = SecureRandom.uuid

        @ws.send_message({
          "type" => "request",
          "conn_id" => conn_id,
          "data" => encoded_data
        })

        response = @ws.wait_for(conn_id, timeout: 10)

        # WS dropped
        return nil if response.nil? && @ws.closed?

        # Success
        return response if response && response["type"] == "response"

        # Master not connected yet — retry with backoff
        if response && response["type"] == "error" && response["reason"] == "master_not_connected"
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining > 0
            Log.debug "[tq-teleport connect] Master not connected yet, retrying in 1s..."
            sleep 1
            next
          end
        end

        # Other error or timeout
        return response
      end
    end

    def attempt_reconnect
      3.times do |i|
        sleep 1
        $stderr.puts "[tq-teleport connect] Reconnecting (attempt #{i + 1}/3)..."
        @ws.reconnect!
        $stderr.puts "[tq-teleport connect] Reconnected."
        return true
      rescue StandardError => e
        $stderr.puts "[tq-teleport connect] Reconnection failed: #{e.message}"
      end
      $stderr.puts "[tq-teleport connect] Giving up after 3 attempts."
      false
    end

    def setup_signal_forwarding(pid)
      %w[INT TERM QUIT].each do |sig|
        Signal.trap(sig) do
          Process.kill(sig, pid) rescue nil
        end
      end
    end

    def cleanup
      @bridge_thread&.kill
      @tcp_server&.close rescue nil
      @ws&.close
    end
  end
end
