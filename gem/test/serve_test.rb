# frozen_string_literal: true

require "test_helper"
require "socket"

class ServeTest < Minitest::Test
  def test_bridge_request_to_local_tcp
    # Start a fake test-queue master that echoes a response
    master = TCPServer.new("127.0.0.1", 0)
    master_port = master.addr[1]

    master_thread = Thread.new do
      client = master.accept
      data = client.readpartial(65536)
      client.write("RESPONSE:#{data}")
      client.close
    end

    serve = TestQueueTeleport::Serve.allocate
    serve.instance_variable_set(:@master_port, master_port)

    response_data = serve.send(:bridge_request, ["POP test 123"].pack("m0"))
    decoded = response_data.unpack1("m0")
    assert_equal "RESPONSE:POP test 123", decoded

    master_thread.join(5)
    master.close
  end

  def test_bridge_request_no_response
    # Fake master that accepts, reads, closes without responding
    master = TCPServer.new("127.0.0.1", 0)
    master_port = master.addr[1]

    master_thread = Thread.new do
      client = master.accept
      client.readpartial(65536)
      client.close
    end

    serve = TestQueueTeleport::Serve.allocate
    serve.instance_variable_set(:@master_port, master_port)

    response_data = serve.send(:bridge_request, ["WORKER data"].pack("m0"))
    assert_equal "", response_data.unpack1("m0")

    master_thread.join(5)
    master.close
  end
end
