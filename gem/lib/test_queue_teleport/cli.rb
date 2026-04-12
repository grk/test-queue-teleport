# frozen_string_literal: true

module TestQueueTeleport
  module CLI
    class ParseError < StandardError; end

    def self.parse(args)
      mode = args[0]
      unless %w[serve connect].include?(mode)
        raise ParseError, "Usage: tq-teleport <serve|connect> -- <command>"
      end

      separator_idx = args.index("--")
      unless separator_idx
        raise ParseError, "Missing '--' separator. Usage: tq-teleport #{mode} -- <command>"
      end

      command = args[(separator_idx + 1)..]
      if command.empty?
        raise ParseError, "Missing command after '--'"
      end

      { mode: mode.to_sym, command: command }
    end

    def self.run(args)
      parsed = parse(args)

      url = ENV.fetch("TQ_TELEPORT_URL") do
        $stderr.puts "Error: TQ_TELEPORT_URL not set"
        return 1
      end

      api_key = ENV.fetch("TQ_TELEPORT_API_KEY") do
        $stderr.puts "Error: TQ_TELEPORT_API_KEY not set"
        return 1
      end

      run_id_input = ENV.fetch("TQ_TELEPORT_RUN_ID") do
        $stderr.puts "Error: TQ_TELEPORT_RUN_ID not set"
        return 1
      end

      run_id = Auth.derive_run_id(api_key, run_id_input)

      encryption_key = if ENV["TQ_TELEPORT_ENCRYPTION_KEY"]
        Cipher.derive_key(ENV["TQ_TELEPORT_ENCRYPTION_KEY"], run_id_input)
      end

      case parsed[:mode]
      when :serve
        Serve.new(
          command: parsed[:command],
          url: url,
          api_key: api_key,
          run_id: run_id,
          encryption_key: encryption_key
        ).run
      when :connect
        Connect.new(
          command: parsed[:command],
          url: url,
          api_key: api_key,
          run_id: run_id,
          encryption_key: encryption_key
        ).run
      end
    rescue ParseError => e
      $stderr.puts "Error: #{e.message}"
      1
    end
  end
end
