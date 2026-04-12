# frozen_string_literal: true

require "test_helper"

class CipherTest < Minitest::Test
  def test_derive_key_is_deterministic
    key_a = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    key_b = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    assert_equal key_a, key_b
  end

  def test_derive_key_differs_for_different_secrets
    key_a = TestQueueTeleport::Cipher.derive_key("secret-a", "run-1")
    key_b = TestQueueTeleport::Cipher.derive_key("secret-b", "run-1")
    refute_equal key_a, key_b
  end

  def test_derive_key_differs_for_different_run_ids
    key_a = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    key_b = TestQueueTeleport::Cipher.derive_key("my-secret", "run-2")
    refute_equal key_a, key_b
  end

  def test_derive_key_returns_32_bytes
    key = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    assert_equal 32, key.bytesize
  end

  def test_round_trip
    key = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    plaintext = "TOKEN=abc\nPOP testhost 123\n"
    encrypted = TestQueueTeleport::Cipher.encrypt(key, plaintext)
    decrypted = TestQueueTeleport::Cipher.decrypt(key, encrypted)
    assert_equal plaintext, decrypted
  end

  def test_encrypted_output_differs_from_plaintext
    key = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    plaintext = "TOKEN=abc\nPOP testhost 123\n"
    encrypted = TestQueueTeleport::Cipher.encrypt(key, plaintext)
    refute_equal plaintext, encrypted
    refute_equal [plaintext].pack("m0"), encrypted
  end

  def test_different_ivs_produce_different_ciphertext
    key = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    plaintext = "same data"
    encrypted_a = TestQueueTeleport::Cipher.encrypt(key, plaintext)
    encrypted_b = TestQueueTeleport::Cipher.encrypt(key, plaintext)
    refute_equal encrypted_a, encrypted_b
  end

  def test_wrong_key_fails_to_decrypt
    key_a = TestQueueTeleport::Cipher.derive_key("secret-a", "run-1")
    key_b = TestQueueTeleport::Cipher.derive_key("secret-b", "run-1")
    plaintext = "sensitive data"
    encrypted = TestQueueTeleport::Cipher.encrypt(key_a, plaintext)
    assert_raises(OpenSSL::Cipher::CipherError) do
      TestQueueTeleport::Cipher.decrypt(key_b, encrypted)
    end
  end

  def test_tampered_ciphertext_fails
    key = TestQueueTeleport::Cipher.derive_key("my-secret", "run-1")
    encrypted = TestQueueTeleport::Cipher.encrypt(key, "data")
    raw = encrypted.unpack1("m0")
    raw.setbyte(15, raw.getbyte(15) ^ 0xFF)
    tampered = [raw].pack("m0")
    assert_raises(OpenSSL::Cipher::CipherError) do
      TestQueueTeleport::Cipher.decrypt(key, tampered)
    end
  end
end
