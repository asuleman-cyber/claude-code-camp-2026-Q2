module Boukensha
  class Agent
    # Default iteration ceiling. The *enforced* value comes from the
    # max_iterations: constructor arg (sourced from Config at the run/repl path),
    # which falls back to this constant. 0 (or nil) disables the ceiling.
    MAX_ITERATIONS = 25

    # The wind-down call is deliberately short and cheap.
    WRAP_UP_OUTPUT_TOKENS = 400
    WRAP_UP_DIRECTIVE = <<~MSG.strip
      You have reached your action limit for this turn. Do not call any more tools.
      Briefly summarize what you accomplished, what is still unfinished, and the
      single next action you would take.
    MSG

    def initialize(context:, registry:, builder:, client:, logger: Logger.new, hooks: Hooks.new,
                   max_iterations: MAX_ITERATIONS, max_turn_tokens: nil, max_output_tokens: nil)
      @context           = context
      @registry          = registry
      @builder           = builder
      @client            = client
      @logger            = logger
      @hooks             = hooks
      @max_iterations    = (max_iterations || MAX_ITERATIONS).to_i
      @max_turn_tokens   = max_turn_tokens.to_i      # 0 = disabled
      @max_output_tokens = max_output_tokens
      @iteration         = 0
    end

    def run
      @context.reset_turn_tokens
      compact_if_needed
      @hooks.before_turn(context: @context)

      loop do
        # Two independent ceilings; stop at whichever trips first. Limits are
        # *trigger thresholds*, not hard caps: when one is reached we stop
        # starting new work iterations and make exactly one terminal wind-down
        # call (counted in tokens, but not as another iteration).
        if iteration_limit_reached?
          @logger.limit_reached(kind: "max_iterations", n: @iteration, max: @max_iterations)
          return wrap_up("max_iterations")
        end
        if token_limit_reached?
          @logger.limit_reached(kind: "max_tokens", n: @context.turn_tokens, max: @max_turn_tokens)
          return wrap_up("max_tokens")
        end

        @iteration += 1
        @hooks.before_model(context: @context)
        @logger.iteration(n: @iteration, max: @max_iterations)
        @logger.prompt(messages: @context.messages, tools: @context.tools, context_window: @context.context_window)

        response = @client.call(**call_opts)
        @logger.raw(data: response)
        parsed   = @builder.parse_response(response)
        record_usage(response)
        log_reasoning(parsed[:content])

        if parsed[:stop_reason] == "tool_use"
          handle_tool_calls(parsed[:content], response)
        else
          text = extract_text(parsed[:content])
          @logger.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason], task: nil, backend: @builder.backend)
          @logger.turn_end(reason: "completed", iterations: @iteration, tokens: @context.turn_tokens)
          @context.add_message(:assistant, text)
          @hooks.after_turn(context: @context, text: text)
          return text
        end
      end
    end

    private

    def iteration_limit_reached?
      @max_iterations.positive? && @iteration >= @max_iterations
    end

    def token_limit_reached?
      @max_turn_tokens.positive? && @context.turn_tokens >= @max_turn_tokens
    end

    # Per-call options shared by every model round-trip of the turn.
    def call_opts
      @max_output_tokens ? { max_output_tokens: @max_output_tokens } : {}
    end

    # Add this call's input+output to the cumulative turn total (the spend
    # budget) and refresh the known context size from input_tokens (compaction
    # pressure). The trigger is evaluated on pre-wrap-up spend; the reported
    # total includes the wind-down call too.
    def record_usage(response)
      usage = response["usage"] || {}
      @context.add_turn_tokens(usage["input_tokens"], usage["output_tokens"])
      @context.update_tokens(usage["input_tokens"].to_i)
    end

    def compact_if_needed
      return unless @context.needs_compaction?

      before  = @context.current_tokens
      dropped = @context.compact_messages!
      @logger.compaction(before: before, dropped: dropped, context_window: @context.context_window)
    end

    # One final, tools-disabled model call so the agent ends the turn in
    # character rather than aborting. Runs *outside* the counted loop: it never
    # re-checks the limits (so it cannot re-trigger) and does not increment
    # @iteration, though its tokens still count toward the reported turn total.
    # Falls back to a deterministic message if the call fails.
    def wrap_up(reason)
      @context.add_message(:user, WRAP_UP_DIRECTIVE)
      response    = @client.call(tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS)
      parsed_wrap = @builder.parse_response(response)
      text        = extract_text(parsed_wrap[:content])
      text        = fallback_message(reason) if text.strip.empty?
      record_usage(response)
      @logger.response(text: text, usage: response["usage"], stop_reason: parsed_wrap[:stop_reason], task: nil, backend: @builder.backend)
      @logger.turn_end(reason: reason, iterations: @iteration, tokens: @context.turn_tokens)
      @context.add_message(:assistant, text)
      @hooks.after_turn(context: @context, text: text)
      text
    rescue ApiError
      msg = fallback_message(reason)
      @logger.turn_end(reason: reason, iterations: @iteration, tokens: @context.turn_tokens)
      @context.add_message(:assistant, msg)
      @hooks.after_turn(context: @context, text: msg)
      msg
    end

    def fallback_message(reason)
      "I reached my #{@max_iterations}-action limit for this turn before finishing " \
      "(#{reason}). Ask me to continue and I'll pick up from here."
    end

    def extract_text(content)
      content.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    end

    # Emit one `reasoning` event per reasoning block so the viewer can show the
    # model's thinking as a first-class step. Empty, non-redacted blocks are
    # skipped to avoid noise (a redacted/omitted block still renders, since it
    # tells the viewer "the model thought here").
    def log_reasoning(content)
      content.each do |block|
        next unless block["type"] == "reasoning"

        redacted = block["redacted"] == true
        text     = block["text"].to_s
        next if text.strip.empty? && !redacted

        @logger.reasoning(text: text, redacted: redacted)
      end
    end

    def handle_tool_calls(content, response)
      tool_calls = content.select { |b| b["type"] == "tool_use" }

      # Log any preamble text that accompanied the tool call (carries no usage —
      # the placeholder below owns the turn's usage chip), then the placeholder.
      preamble = extract_text(content)
      @logger.plan(text: preamble) unless preamble.strip.empty?
      @logger.response(text: "(tool use — #{tool_calls.size} call#{'s' if tool_calls.size != 1})", usage: response["usage"], stop_reason: "tool_use")

      @context.add_message(:assistant, content)

      # Fires once, before the first dispatch — the only moment output that
      # arrived while the model was thinking (the longest gap in the loop)
      # is still recoverable, per lifecycle_hooks.md / basic_memory.md §5.6.
      @hooks.before_tools(calls: tool_calls, context: @context)

      tool_calls.each do |block|
        name   = block["name"]
        args   = block["input"]
        use_id = block["id"]

        @logger.tool_call(name: name, args: args)
        begin
          result = @registry.dispatch(name, args)
          @logger.tool_result(name: name, result: result, ok: true)
        rescue StandardError => e
          result = "ERROR: #{e.class}: #{e.message}"
          @logger.tool_result(name: name, result: result, ok: false, error: e.message)
        end

        # A hook may replace what the MODEL sees (e.g. a parsed "moved north
        # -> Market Square" stub instead of the room's full prose) without
        # touching what was just logged above — the session log/mud_monitor
        # keep the MUD's exact words regardless.
        model_result = @hooks.after_tool(name: name, args: args, result: result, context: @context) || result

        @context.add_message(:tool_result, model_result.to_s, tool_use_id: use_id)
      end
    end
  end
end
