module Boukensha
  # Repl is the interactive session loop.
  #
  # It wraps the same primitives as a single Boukensha.run call, but instead of
  # running once it stays alive: it reads a task from the user, runs the agent,
  # prints the reply, and loops back to the prompt.
  #
  # The Context is shared across every turn so conversation history accumulates
  # naturally — the agent sees the full transcript each time it is called.
  #
  # Built-in commands (not sent to the agent):
  #   /help    print the command list
  #   /quiet   suppress detailed logging
  #   /loud    re-enable logging
  #   /clear   wipe conversation history (tools stay registered)
  #   /compact drop oldest 40% of messages to free context
  #   /exit    leave the REPL
  #   /quit    alias for /exit
  class Repl
    PROMPT = "boukensha> "

    HELP = <<~HELP
      Commands:
        /quiet    suppress logging output
        /loud     re-enable logging output
        /clear    wipe conversation history (tools stay)
        /compact  drop oldest 40% of messages to free context
        /plan     show the plan the Planner is working to
        /exit     leave the REPL
        /help     show this message
    HELP

    attr_reader :logger, :context, :model, :version

    def initialize(context:, registry:, builder:, client:, logger:, hooks: Hooks.new, error_log: nil, config_dir: nil, provider: nil, model: nil, version: nil, api_key: nil, servers: nil, max_iterations: nil, max_turn_tokens: nil, max_output_tokens: nil, orchestrator: nil)
      @context    = context
      @registry   = registry
      @builder    = builder
      @client     = client
      @logger     = logger
      @hooks      = hooks
      @error_log  = error_log
      @config_dir = config_dir
      @provider   = provider
      @model      = model
      @version    = version
      @api_key    = api_key
      @servers    = servers
      @max_iterations    = max_iterations
      @max_turn_tokens   = max_turn_tokens
      @max_output_tokens = max_output_tokens
      # nil unless settings.yaml switched on the Planner or the Judge — every
      # use below is guarded, so the un-orchestrated REPL is byte-for-byte the
      # loop it was before Phase G.
      @orchestrator = orchestrator
      @turn       = 0
      @output_cb  = nil
    end

    # Register a callback that receives every string the REPL would otherwise
    # print to stdout.  When set, puts/print are suppressed entirely and all
    # output is routed through the callback instead.  Used by Tui.
    def on_output(&block)
      @output_cb = block
    end

    def banner
      key_status    = (@api_key.nil? || @api_key.strip.empty?) ? "✗ API key not set" : "✓ API key set"
      provider_line = "#{@provider || "default"} (#{@model || "default"})  #{key_status}"
      config_exists = @config_dir && Dir.exist?(@config_dir)
      config_line   = config_exists ? @config_dir : "#{@config_dir || "(default)"}  ✗ directory not found"
      ver           = @version || "?.?.?"
      servers_stat  = servers_status_string

      <<~BANNER

        ╔══════════════════════════════════════╗
        ║  BOUKENSHA MUD Assistant (v#{ver})#{" " * (9 - ver.length)}║
        ╚══════════════════════════════════════╝
          config:    #{config_line}
          provider:  #{provider_line}
          servers:   #{servers_stat}

          /quiet or /loud   toggle logging
          /clear           reset conversation history
          /compact         free context (drop oldest messages)
          /exit or /quit    leave the REPL

      BANNER
    end

    # Handle a slash command.  Returns :quit, :command, or nil (not a command).
    # Output is routed through the registered on_output callback if present.
    def handle_command(input)
      case input
      when "/exit", "/quit"
        output("Goodbye.")
        :quit
      when "/help"
        output(HELP)
        :command
      when "/quiet"
        Boukensha.quiet!
        output("(logging suppressed — type /loud to re-enable)")
        :command
      when "/loud"
        Boukensha.loud!
        output("(logging enabled)")
        :command
      when "/clear"
        @context.clear_messages!
        # The plan goes with the history it was written for. Keeping it would
        # leave the agent working to a plan whose whole rationale — the
        # conversation that produced it — no longer exists; the next turn
        # plans fresh instead.
        @context.plan   = nil
        @replan_pending = false
        @turn = 0
        output("(conversation history cleared)")
        :command
      when "/compact"
        dropped = @context.compact_messages!
        output("(compacted context — #{dropped} messages dropped)")
        :command
      when "/plan"
        output(@context.plan ? "Current plan:\n\n#{@context.plan}" : "(no plan — the planner is off, or hasn't run yet)")
        :command
      end
    end

    def run_turn(input)
      @turn += 1
      @logger.turn(n: @turn)

      plan_if_needed(input)
      @context.add_message(:user, input)

      agent  = Agent.new(
        context:  @context,
        registry: @registry,
        builder:  @builder,
        client:   @client,
        logger:   @logger,
        hooks:    @hooks,
        max_iterations:    @max_iterations,
        max_turn_tokens:   @max_turn_tokens,
        max_output_tokens: @max_output_tokens,
        task:     Tasks::Player
      )
      result = agent.run

      output("")
      output(result)
      judge_if_due(agent.stop_reason)
    rescue LoopError => e
      output("\n[error] #{e.message}")
    rescue ApiError => e
      output("\n[error] API call failed: #{e.message}")
    rescue StandardError => e
      # A genuinely unexpected error used to crash the whole REPL process
      # (nothing below LoopError/ApiError was ever caught here) — Phase F.
      # This is the safety net: log it with a backtrace, keep the session
      # alive so the user doesn't lose their conversation over one bad turn.
      @error_log&.record(e, context: "Repl#run_turn")
      output("\n[error] #{e.class}: #{e.message} (logged; the session is still alive — try again)")
    end

    def start
      output(banner)
      loop do
        unless @output_cb
          print PROMPT
          $stdout.flush
        end

        input = $stdin.gets
        break unless input  # EOF / Ctrl-D

        input = input.chomp.strip
        next if input.empty?

        result = handle_command(input)
        break if result == :quit
        next  if result

        run_turn(input)
      end
    end

    private

    # Plan before the Player's first turn, and again after a :replan verdict.
    #
    # Not before every turn: a plan that is rewritten each time the user
    # speaks is just an expensive paraphrase of what they said. It is
    # rewritten when there is nothing to work from, or when the Judge has
    # said the current plan is finished or failed.
    def plan_if_needed(input)
      return unless @orchestrator&.planner_enabled?
      return unless @context.plan.nil? || @replan_pending

      @replan_pending = false
      plan = @orchestrator.plan!(goal: input, context: @context)
      output("\n[planner]\n#{plan}") if plan
    end

    # Checkpoint after the Player's turn. A verdict never silently changes
    # what happens next — :replan schedules a new plan for the next turn and
    # :flag says so out loud — because this is the interactive REPL and there
    # is a human right there who should get to decide what to do about it.
    def judge_if_due(stop_reason)
      return unless @orchestrator&.judge_due?(stop_reason)

      verdict = @orchestrator.judge!(context: @context, stop_reason: stop_reason)
      case verdict
      when :replan
        @replan_pending = true
        output("\n[judge] replan — the current plan is done or not working; " \
               "the next thing you ask will be planned fresh.")
      when :flag
        output("\n[judge] flag — this needs a look. #{@orchestrator.verdict_text}".rstrip)
      end
    end

    def output(str)
      if @output_cb
        @output_cb.call(str.to_s)
      else
        puts str
      end
    end

    # Build the MCP servers line shown in the banner. Every tool the agent has
    # came from one of these, so this doubles as "what can I actually do?".
    # No probing needed: a server that answers tools/list is already connected,
    # and one that didn't is either absent here or took the agent down at boot.
    def servers_status_string
      return "(none configured — the agent has no tools)" if @servers.nil? || @servers.empty?

      @servers.map { |name, count| "#{name} (#{count})" }.join("  ")
    end
  end
end
