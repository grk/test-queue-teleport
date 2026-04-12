# frozen_string_literal: true

require "test_helper"

class ServeInFlightTest < Minitest::Test
  def test_wait_for_in_flight_returns_when_count_reaches_zero
    serve = TestQueueTeleport::Serve.allocate
    serve.instance_variable_set(:@in_flight, Mutex.new)
    serve.instance_variable_set(:@in_flight_count, 0)
    serve.instance_variable_set(:@in_flight_zero, ConditionVariable.new)
    serve.instance_variable_set(:@in_flight_timeout, 10)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    serve.send(:wait_for_in_flight)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert elapsed < 1.0, "wait_for_in_flight should return immediately when count is zero"
  end

  def test_wait_for_in_flight_waits_then_returns
    serve = TestQueueTeleport::Serve.allocate
    mutex = Mutex.new
    serve.instance_variable_set(:@in_flight, mutex)
    serve.instance_variable_set(:@in_flight_count, 1)
    cv = ConditionVariable.new
    serve.instance_variable_set(:@in_flight_zero, cv)
    serve.instance_variable_set(:@in_flight_timeout, 10)

    Thread.new do
      sleep 0.5
      mutex.synchronize do
        serve.instance_variable_set(:@in_flight_count, 0)
        cv.signal
      end
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    serve.send(:wait_for_in_flight)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert elapsed >= 0.4, "should wait for count to reach zero"
    assert elapsed < 2.0, "should not wait much longer than needed"
  end

  def test_wait_for_in_flight_times_out
    serve = TestQueueTeleport::Serve.allocate
    serve.instance_variable_set(:@in_flight, Mutex.new)
    serve.instance_variable_set(:@in_flight_count, 1)
    serve.instance_variable_set(:@in_flight_zero, ConditionVariable.new)
    serve.instance_variable_set(:@in_flight_timeout, 1)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    serve.send(:wait_for_in_flight)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert elapsed >= 0.9, "should wait for timeout"
    assert elapsed < 2.0, "should not wait much longer than timeout"
  end
end
