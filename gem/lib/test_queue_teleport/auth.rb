# frozen_string_literal: true

require "openssl"

module TestQueueTeleport
  module Auth
    def self.derive_run_id(api_key, teleport_run_id)
      OpenSSL::HMAC.hexdigest("SHA256", api_key, teleport_run_id)
    end
  end
end
