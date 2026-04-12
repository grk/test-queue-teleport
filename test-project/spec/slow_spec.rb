# frozen_string_literal: true

RSpec.describe "Slow suite" do
  10.times do |i|
    it "passes slow test #{i + 1}" do
      sleep(rand(2.0..3.0))
      expect(true).to be true
    end
  end
end
