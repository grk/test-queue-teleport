# frozen_string_literal: true

module TestQueueTeleport
  module Log
    def self.debug(msg)
      $stderr.puts msg if ENV["TQ_TELEPORT_DEBUG"]
    end
  end
end
