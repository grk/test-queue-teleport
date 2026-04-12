# frozen_string_literal: true

require "test_helper"

class WsClientReconnectTest < Minitest::Test
  def test_explicitly_closed_is_false_initially
    ws = TestQueueTeleport::WsClient.allocate
    ws.instance_variable_set(:@explicitly_closed, false)
    ws.instance_variable_set(:@closed, false)

    refute ws.explicitly_closed?
  end

  def test_explicitly_closed_is_true_after_close
    ws = TestQueueTeleport::WsClient.allocate
    ws.instance_variable_set(:@explicitly_closed, false)
    ws.instance_variable_set(:@closed, false)
    ws.instance_variable_set(:@socket, nil)
    ws.instance_variable_set(:@write_mutex, Mutex.new)
    ws.instance_variable_set(:@waiters, {})
    ws.instance_variable_set(:@waiters_mutex, Mutex.new)
    ws.instance_variable_set(:@next_queue, [])
    ws.instance_variable_set(:@next_mutex, Mutex.new)
    ws.instance_variable_set(:@next_cv, ConditionVariable.new)

    ws.close

    assert ws.explicitly_closed?
    assert ws.closed?
  end

  def test_reconnect_raises_if_explicitly_closed
    ws = TestQueueTeleport::WsClient.allocate
    ws.instance_variable_set(:@explicitly_closed, true)
    ws.instance_variable_set(:@closed, true)

    assert_raises(RuntimeError) { ws.reconnect! }
  end
end
