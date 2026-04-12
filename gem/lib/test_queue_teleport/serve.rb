# frozen_string_literal: true

require "socket"

module TestQueueTeleport
  class Serve
    def initialize(command:, url:, api_key:, run_id:, encryption_key: nil)
      @command = command
      @url = url
      @api_key = api_key
      @run_id = run_id
      @encryption_key = encryption_key
    end

    def run
      # Pick a random port for test-queue to listen on
      temp_server = TCPServer.new("127.0.0.1", 0)
      @master_port = temp_server.addr[1]
      temp_server.close

      @in_flight = Mutex.new
      @in_flight_count = 0
      @in_flight_zero = ConditionVariable.new
      @in_flight_timeout = 10

      # Connect WebSocket to DO as master
      ws_url = "#{@url}?role=master&run_id=#{@run_id}"
      $stderr.puts "[tq-teleport serve] Connecting as master..."
      @ws = WsClient.new(ws_url, api_key: @api_key)
      $stderr.puts "[tq-teleport serve] Connected. Master socket: 127.0.0.1:#{@master_port}"

      # Start bridge thread — bridge_request retries if master isn't ready yet
      @bridge_thread = Thread.new { bridge_loop }

      # Spawn test-queue
      env = {
        "TEST_QUEUE_SOCKET" => "127.0.0.1:#{@master_port}",
        "TEST_QUEUE_RELAY_TOKEN" => @run_id
      }
      pid = Process.spawn(env, *@command)

      setup_signal_forwarding(pid)

      _, status = Process.waitpid2(pid)

      @child_exited = true
      wait_for_in_flight
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

        msg = @ws.receive_next(timeout: 5)
        next if msg.nil?

        conn_id = msg["conn_id"]
        next unless conn_id

        # Handle each message in its own thread for concurrency
        @in_flight.synchronize { @in_flight_count += 1 }

        Thread.new(msg, conn_id) do |m, cid|
          incoming_data = m["data"]
          incoming_data = Cipher.decrypt(@encryption_key, incoming_data) if @encryption_key

          response_data = bridge_request(incoming_data)

          if m["type"] == "request"
            if response_data.nil?
              # Master unavailable — send error so connect side can RST the TCP socket
              @ws.send_message({
                "type" => "error",
                "conn_id" => cid,
                "reason" => "master_unavailable"
              })
            else
              response_data = Cipher.encrypt(@encryption_key, response_data) if @encryption_key
              @ws.send_message({
                "type" => "response",
                "conn_id" => cid,
                "data" => response_data
              })
            end
          end
        rescue StandardError => e
          $stderr.puts "[tq-teleport serve] Bridge error: #{e.message}"
        ensure
          @in_flight.synchronize do
            @in_flight_count -= 1
            @in_flight_zero.signal if @in_flight_count == 0
          end
        end
      rescue StandardError => e
        $stderr.puts "[tq-teleport serve] Bridge loop error: #{e.message}"
      end
    end

    def attempt_reconnect
      3.times do |i|
        sleep 1
        $stderr.puts "[tq-teleport serve] Reconnecting (attempt #{i + 1}/3)..."
        @ws.reconnect!
        $stderr.puts "[tq-teleport serve] Reconnected."
        return true
      rescue StandardError => e
        $stderr.puts "[tq-teleport serve] Reconnection failed: #{e.message}"
      end
      $stderr.puts "[tq-teleport serve] Giving up after 3 attempts."
      false
    end

    def bridge_request(encoded_data)
      raw_data = encoded_data.unpack1("m0")
      Log.debug "[tq-teleport serve] Forwarding #{raw_data.bytesize} bytes to master"

      sock = connect_to_master
      return nil unless sock

      sock.write(raw_data)
      sock.shutdown(Socket::SHUT_WR)

      response = +""
      loop do
        ready = IO.select([sock], nil, nil, 5.0)
        break unless ready

        begin
          chunk = sock.readpartial(65536)
          response << chunk
        rescue EOFError
          break
        end
      end

      Log.debug "[tq-teleport serve] Got #{response.bytesize} bytes response from master"
      sock.close
      [response].pack("m0")
    rescue Errno::ECONNRESET
      [""].pack("m0")
    end

    def connect_to_master
      retries = 0
      begin
        TCPSocket.new("127.0.0.1", @master_port)
      rescue Errno::ECONNREFUSED
        return nil if @child_exited

        retries += 1
        if retries <= 20
          sleep 0.5
          retry
        end
        $stderr.puts "[tq-teleport serve] Master not available after #{retries} retries"
        nil
      end
    end

    def setup_signal_forwarding(pid)
      %w[INT TERM QUIT].each do |sig|
        Signal.trap(sig) do
          Process.kill(sig, pid) rescue nil
        end
      end
    end

    def wait_for_in_flight
      @in_flight.synchronize do
        unless @in_flight_count == 0
          Log.debug "[tq-teleport serve] Waiting for #{@in_flight_count} in-flight requests..."
          @in_flight_zero.wait(@in_flight, @in_flight_timeout)
        end
      end
    end

    def cleanup
      @bridge_thread&.kill
      @ws&.close
    end
  end
end
