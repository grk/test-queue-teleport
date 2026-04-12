# frozen_string_literal: true

require "openssl"

module TestQueueTeleport
  module Cipher
    def self.derive_key(encryption_key, run_id)
      OpenSSL::KDF.hkdf(
        encryption_key,
        salt: run_id,
        info: "tq-teleport-e2e",
        length: 32,
        hash: "SHA256"
      )
    end

    def self.encrypt(key, plaintext)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      cipher.key = key
      iv = cipher.random_iv
      ciphertext = cipher.update(plaintext) + cipher.final
      auth_tag = cipher.auth_tag
      [iv + ciphertext + auth_tag].pack("m0")
    end

    def self.decrypt(key, encoded)
      raw = encoded.unpack1("m0")
      iv = raw.byteslice(0, 12)
      auth_tag = raw.byteslice(-16, 16)
      ciphertext = raw.byteslice(12, raw.bytesize - 28)

      cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      cipher.key = key
      cipher.iv = iv
      cipher.auth_tag = auth_tag
      cipher.update(ciphertext) + cipher.final
    end
  end
end
