# frozen_string_literal: true

require_relative "lib/test_queue_teleport/version"

Gem::Specification.new do |spec|
  spec.name = "test-queue-teleport"
  spec.version = TestQueueTeleport::VERSION
  spec.authors = ["Grzegorz Kołodziejczyk"]
  spec.summary = "test-queue distributed mode over Cloudflare"
  spec.description = "Bridges test-queue's TCP protocol through a Cloudflare Durable Object, enabling distributed test runs on any CI."
  spec.homepage = "https://github.com/grk/test-queue-teleport"
  spec.license = "O'Saasy"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "exe/*"]
  spec.bindir = "exe"
  spec.executables = ["tq-teleport"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
