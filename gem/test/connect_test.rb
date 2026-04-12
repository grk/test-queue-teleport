# frozen_string_literal: true

require "test_helper"
require "socket"

class FakeWsClient
  attr_reader :last_sent

  def initialize
    @last_sent = nil
    @responses = {}
    @waiters = {}
    @lock = Mutex.new
  end

  def closed?
    false
  end

  def send_message(hash)
    @lock.synchronize { @last_sent = hash }
  end

  def wait_for(conn_id, timeout: 30)
    cv = ConditionVariable.new
    mutex = Mutex.new

    @lock.synchronize { @waiters[conn_id] = { cv: cv, mutex: mutex } }

    mutex.synchronize do
      deadline = Time.now + timeout
      loop do
        @lock.synchronize do
          return @responses.delete(conn_id) if @responses.key?(conn_id)
        end
        remaining = deadline - Time.now
        return nil if remaining <= 0
        cv.wait(mutex, remaining)
      end
    end
  end

  def provide_response(conn_id, data)
    @lock.synchronize do
      @responses[conn_id] = {
        "type" => "response",
        "conn_id" => conn_id,
        "data" => data
      }
      if @waiters[conn_id]
        @waiters[conn_id][:cv].signal
      end
    end
  end

  def close; end
end

class ConnectTest < Minitest::Test
  def test_bridge_tcp_to_ws_and_back
    fake_ws = FakeWsClient.new

    connect = TestQueueTeleport::Connect.allocate
    tcp_server = TCPServer.new("127.0.0.1", 0)
    port = tcp_server.addr[1]
    connect.instance_variable_set(:@tcp_server, tcp_server)
    connect.instance_variable_set(:@ws, fake_ws)

    # Start bridge handling in a thread
    bridge_thread = Thread.new { connect.send(:handle_connection, tcp_server.accept) }

    # Simulate test-queue relay connecting and sending a POP
    client = TCPSocket.new("127.0.0.1", port)
    client.write("TOKEN=abc\nPOP testhost 123\n")
    client.close_write # signal EOF so bridge reads all data

    # Wait for the bridge to send the WS message
    sleep 0.3

    # Verify what was sent through WS
    sent_msg = fake_ws.last_sent
    assert_equal "request", sent_msg["type"]
    assert sent_msg["conn_id"]
    decoded = sent_msg["data"].unpack1("m0")
    assert_equal "TOKEN=abc\nPOP testhost 123\n", decoded

    # Provide the response (simulating DO → master → DO → worker)
    fake_ws.provide_response(sent_msg["conn_id"], ["marshalled_suite_data"].pack("m0"))

    # Bridge should write response to TCP and close
    bridge_thread.join(5)

    response = client.read
    assert_equal "marshalled_suite_data", response

    client.close
    tcp_server.close
  end
end
