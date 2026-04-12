# frozen_string_literal: true

require "test_helper"

class CLITest < Minitest::Test
  def test_parse_serve_command
    args = ["serve", "--", "bundle", "exec", "rspec-queue", "spec/"]
    result = TestQueueTeleport::CLI.parse(args)

    assert_equal :serve, result[:mode]
    assert_equal ["bundle", "exec", "rspec-queue", "spec/"], result[:command]
  end

  def test_parse_connect_command
    args = ["connect", "--", "bundle", "exec", "rspec-queue", "spec/"]
    result = TestQueueTeleport::CLI.parse(args)

    assert_equal :connect, result[:mode]
    assert_equal ["bundle", "exec", "rspec-queue", "spec/"], result[:command]
  end

  def test_parse_missing_separator
    assert_raises(TestQueueTeleport::CLI::ParseError) do
      TestQueueTeleport::CLI.parse(["serve", "bundle", "exec", "rspec-queue"])
    end
  end

  def test_parse_unknown_mode
    assert_raises(TestQueueTeleport::CLI::ParseError) do
      TestQueueTeleport::CLI.parse(["unknown", "--", "rspec-queue"])
    end
  end

  def test_parse_missing_command_after_separator
    assert_raises(TestQueueTeleport::CLI::ParseError) do
      TestQueueTeleport::CLI.parse(["serve", "--"])
    end
  end
end
