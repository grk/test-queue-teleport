# frozen_string_literal: true

require "test_helper"

class AuthTest < Minitest::Test
  def test_derive_run_id_is_deterministic
    run_id_a = TestQueueTeleport::Auth.derive_run_id("my-api-key", "run-123")
    run_id_b = TestQueueTeleport::Auth.derive_run_id("my-api-key", "run-123")

    assert_equal run_id_a, run_id_b
  end

  def test_derive_run_id_differs_for_different_keys
    run_id_a = TestQueueTeleport::Auth.derive_run_id("key-a", "run-123")
    run_id_b = TestQueueTeleport::Auth.derive_run_id("key-b", "run-123")

    refute_equal run_id_a, run_id_b
  end

  def test_derive_run_id_differs_for_different_runs
    run_id_a = TestQueueTeleport::Auth.derive_run_id("my-api-key", "run-1")
    run_id_b = TestQueueTeleport::Auth.derive_run_id("my-api-key", "run-2")

    refute_equal run_id_a, run_id_b
  end

  def test_derive_run_id_returns_hex_string
    run_id = TestQueueTeleport::Auth.derive_run_id("my-api-key", "run-123")

    assert_match(/\A[0-9a-f]{64}\z/, run_id)
  end
end
