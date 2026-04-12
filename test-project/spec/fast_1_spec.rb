# frozen_string_literal: true

RSpec.describe "Fast suite 1" do
  5.times do |i|
    it "passes test #{i + 1}" do
      puts "Fast 1 test #{i + 1} on #{ENV['TEST_QUEUE_RELAY'] ? 'worker' : 'master'} (pid #{Process.pid})"
      sleep(rand(0.5..1.0))
      expect(true).to be true
    end
  end
end
