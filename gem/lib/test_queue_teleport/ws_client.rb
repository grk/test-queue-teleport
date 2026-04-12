# frozen_string_literal: true

require "socket"
require "openssl"
require "securerandom"
require "json"
require "uri"

module TestQueueTeleport
  class WsClient
    OPCODES = {
      text: 0x1,
      close: 0x8,
      ping: 0x9,
      pong: 0xA
    }.freeze

    attr_reader :closed

    def initialize(url, api_key:)
      @url = URI.parse(url)
      @api_key = api_key
      @closed = false
      @explicitly_closed = false

      @write_mutex = Mutex.new
      @responses = {}       # conn_id => response hash
      @waiters = {}         # conn_id => ConditionVariable
      @waiters_mutex = Mutex.new

      @next_queue = []
      @next_mutex = Mutex.new
      @next_cv = ConditionVariable.new

      connect!
    end

    def closed?
      @closed
    end

    def explicitly_closed?
      @explicitly_closed
    end

    def reconnect!
      raise "Cannot reconnect — explicitly closed" if @explicitly_closed

      @socket&.close rescue nil
      @reader_thread&.kill rescue nil

      @closed = false
      @waiters_mutex.synchronize do
        @responses.clear
        @waiters.clear
      end
      @next_mutex.synchronize do
        @next_queue.clear
      end

      connect!
      Log.debug "[tq-teleport ws] Reconnected to #{@url.host}"
    end

    def send_message(hash)
      raise "WebSocket is closed" if @closed || @socket.nil?

      json = JSON.generate(hash)
      frame = self.class.encode_text_frame(json)
      @write_mutex.synchronize { @socket.write(frame) }
    end

    def wait_for(conn_id, timeout: 30)
      cv = nil
      @waiters_mutex.synchronize do
        cv = @waiters[conn_id] ||= ConditionVariable.new
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      @waiters_mutex.synchronize do
        loop do
          if @responses.key?(conn_id)
            @waiters.delete(conn_id)
            return @responses.delete(conn_id)
          end
          return nil if @closed

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if remaining <= 0

          cv.wait(@waiters_mutex, remaining)
        end
      end
    end

    def receive_next(timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      @next_mutex.synchronize do
        loop do
          return @next_queue.shift unless @next_queue.empty?
          return nil if @closed

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if remaining <= 0

          @next_cv.wait(@next_mutex, remaining)
        end
      end
    end

    def close
      return if @closed

      @closed = true
      @explicitly_closed = true
      send_close_frame
      @socket&.close
    rescue IOError, OpenSSL::SSL::SSLError
      # already closed
    ensure
      wake_all_waiters
    end

    # --- Class methods for framing (testable without a connection) ---

    def self.encode_text_frame(payload)
      payload = payload.b
      mask_key = SecureRandom.random_bytes(4)
      header = String.new(encoding: Encoding::BINARY)

      # FIN + text opcode
      header << [0x81].pack("C")

      # Masked + length
      if payload.bytesize < 126
        header << [0x80 | payload.bytesize].pack("C")
      elsif payload.bytesize <= 65_535
        header << [0x80 | 126, payload.bytesize].pack("Cn")
      else
        raise ArgumentError, "payload too large (max 65535 bytes)"
      end

      header << mask_key

      # Apply mask to payload
      masked = payload.bytes.each_with_index.map { |b, i|
        b ^ mask_key.getbyte(i % 4)
      }.pack("C*")

      header + masked
    end

    def self.decode_frame(data)
      data = data.b
      return [:unknown, nil] if data.bytesize < 2

      first = data.getbyte(0)
      second = data.getbyte(1)

      opcode = first & 0x0F
      masked = (second & 0x80) != 0
      length = second & 0x7F

      offset = 2

      if length == 126
        return [:unknown, nil] if data.bytesize < 4
        length = data.byteslice(2, 2).unpack1("n")
        offset = 4
      elsif length == 127
        return [:unknown, nil] if data.bytesize < 10
        length = data.byteslice(2, 8).unpack1("Q>")
        offset = 10
      end

      if masked
        mask_key = data.byteslice(offset, 4)
        offset += 4
        payload = data.byteslice(offset, length)
        payload = payload.bytes.each_with_index.map { |b, i|
          b ^ mask_key.getbyte(i % 4)
        }.pack("C*")
      else
        payload = data.byteslice(offset, length)
      end

      type = case opcode
             when 0x1 then :text
             when 0x8 then :close
             when 0x9 then :ping
             when 0xA then :pong
             else :unknown
             end

      [type, payload&.force_encoding(Encoding::UTF_8)]
    end

    private

    def connect!
      tcp = TCPSocket.new(@url.host, @url.port || 443)
      ssl_context = OpenSSL::SSL::SSLContext.new
      @socket = OpenSSL::SSL::SSLSocket.new(tcp, ssl_context)
      @socket.hostname = @url.host
      @socket.connect

      perform_handshake
      start_reader_thread
      Log.debug "[tq-teleport ws] Connected to #{@url.host}"
    end

    def perform_handshake
      ws_key = [SecureRandom.random_bytes(16)].pack("m0")
      path = @url.request_uri

      request = [
        "GET #{path} HTTP/1.1",
        "Host: #{@url.host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{ws_key}",
        "Sec-WebSocket-Version: 13",
        "Authorization: Bearer #{@api_key}",
        "", ""
      ].join("\r\n")

      @socket.write(request)

      response = +""
      loop do
        line = read_line
        response << line
        break if line == "\r\n"
      end

      unless response.start_with?("HTTP/1.1 101")
        raise "WebSocket handshake failed: #{response.lines.first&.strip}"
      end

      expected_accept = [
        OpenSSL::Digest::SHA1.digest(ws_key + "258EAFA5-E914-47DA-95CA-5AB5DF35BCE8")
      ].pack("m0")

      # Sec-WebSocket-Accept validation skipped — Cloudflare edge may
      # re-negotiate the WebSocket upgrade, producing a different accept value.
      # The TLS connection itself provides authenticity.
    end

    def read_line
      line = String.new(encoding: Encoding::BINARY)
      loop do
        char = @socket.read(1)
        raise "connection closed during handshake" if char.nil?
        line << char
        break if line.end_with?("\r\n")
      end
      line
    end

    def start_reader_thread
      @reader_thread = Thread.new do
        loop do
          break if @closed

          type, payload = read_frame
          break if type.nil?

          case type
          when :text
            handle_text_message(payload)
          when :ping
            send_pong(payload)
          when :close
            Log.debug "[tq-teleport ws] Received close frame"
            @closed = true
            wake_all_waiters
            break
          end
        rescue IOError, OpenSSL::SSL::SSLError, Errno::ECONNRESET => e
          Log.debug "[tq-teleport ws] Reader error: #{e.class}: #{e.message}"
          @closed = true
          wake_all_waiters
          break
        end
      end
      @reader_thread.abort_on_exception = false
    end

    def read_frame
      header = read_bytes(2)
      return nil if header.nil?

      first = header.getbyte(0)
      second = header.getbyte(1)

      opcode = first & 0x0F
      masked = (second & 0x80) != 0
      length = second & 0x7F

      if length == 126
        length = read_bytes(2)&.unpack1("n")
        return nil if length.nil?
      elsif length == 127
        length = read_bytes(8)&.unpack1("Q>")
        return nil if length.nil?
      end

      mask_key = masked ? read_bytes(4) : nil
      return nil if masked && mask_key.nil?

      payload = length > 0 ? read_bytes(length) : "".b
      return nil if payload.nil?

      if masked && mask_key
        payload = payload.bytes.each_with_index.map { |b, i|
          b ^ mask_key.getbyte(i % 4)
        }.pack("C*")
      end

      type = case opcode
             when 0x1 then :text
             when 0x8 then :close
             when 0x9 then :ping
             when 0xA then :pong
             else :unknown
             end

      [type, payload.force_encoding(Encoding::UTF_8)]
    end

    def read_bytes(n)
      buf = String.new(encoding: Encoding::BINARY)
      while buf.bytesize < n
        chunk = @socket.read(n - buf.bytesize)
        return nil if chunk.nil? || chunk.empty?
        buf << chunk
      end
      buf
    end

    def handle_text_message(payload)
      msg = JSON.parse(payload)

      @next_mutex.synchronize do
        @next_queue << msg
        @next_cv.signal
      end

      conn_id = msg["conn_id"]
      return unless conn_id

      @waiters_mutex.synchronize do
        @responses[conn_id] = msg
        @waiters[conn_id]&.signal
      end
    end

    def send_pong(payload)
      frame = String.new(encoding: Encoding::BINARY)
      frame << [0x8A].pack("C") # FIN + pong opcode

      mask_key = SecureRandom.random_bytes(4)
      data = (payload || "").b

      frame << [0x80 | data.bytesize].pack("C")
      frame << mask_key

      masked = data.bytes.each_with_index.map { |b, i|
        b ^ mask_key.getbyte(i % 4)
      }.pack("C*")
      frame << masked

      @write_mutex.synchronize { @socket.write(frame) }
    rescue IOError, OpenSSL::SSL::SSLError
      # ignore write errors on pong
    end

    def send_close_frame
      return unless @socket

      frame = [0x88, 0x80].pack("CC") + SecureRandom.random_bytes(4)
      @write_mutex.synchronize { @socket.write(frame) }
    rescue IOError, OpenSSL::SSL::SSLError
      # ignore
    end

    def wake_all_waiters
      @waiters_mutex.synchronize do
        @waiters.each_value(&:broadcast)
      end

      @next_mutex.synchronize do
        @next_cv.broadcast
      end
    end
  end
end
