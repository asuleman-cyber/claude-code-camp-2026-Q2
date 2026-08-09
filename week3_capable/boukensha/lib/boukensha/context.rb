require_relative "tool"
require_relative "message"

module Boukensha
  class Context
    # The heading the Planner's plan is filed under inside the system prompt.
    PLAN_HEADING = "## Your current plan".freeze

    attr_reader :base_system, :tools, :context_window, :working_dir,
                :turn_tokens, :compaction_threshold
    attr_accessor :current_tokens, :state_block, :plan

    def initialize(system:, context_window: 200_000, working_dir: nil, compaction_threshold: 0.85)
      @base_system          = system
      @context_window       = context_window
      @working_dir          = working_dir ? File.expand_path(working_dir) : nil
      @compaction_threshold = compaction_threshold
      @messages             = []
      @tools                = {}
      @current_tokens       = 0
      @turn_tokens          = 0
      @state_block          = nil
      @plan                 = nil
    end

    # The system prompt a request actually sends: the task's own prompt with
    # the Planner's plan (if any) appended under PLAN_HEADING.
    #
    # The plan lives in the SYSTEM prompt rather than in @messages on purpose.
    # #compact_messages! drops the oldest 40% of history the moment the window
    # fills, so a plan delivered as an ordinary message is exactly the kind of
    # thing that silently disappears mid-session — the agent keeps playing with
    # no idea what it was trying to do. The system prompt is never compacted,
    # so the plan survives for as long as it is set.
    #
    # Composed on read, never stored, so re-planning is a plain assignment and
    # can't leave a stale copy behind. Every backend calls `context.system`
    # (Anthropic `system:`, Gemini `systemInstruction`, OpenAI `instructions`,
    # both Ollamas' leading system message), so all five get this for free with
    # zero per-backend plumbing — the same trick #messages uses for state_block.
    def effective_system
      return @base_system if @plan.nil? || @plan.to_s.strip.empty?

      "#{@base_system}\n\n#{PLAN_HEADING}\n\n#{@plan.to_s.strip}"
    end
    alias system effective_system

    def register_tool(tool)
      @tools[tool.name] = tool
    end

    # The messages a request actually sends. `state_block` (if set — see
    # Boukensha::Hooks / Mud::Hooks#before_model) is appended as a synthetic
    # trailing user-role message here, NOT stored in @messages: it is
    # re-rendered fresh before every model call, so it is never duplicated,
    # never stale, and never survives to be compacted as if it were history.
    # Every caller of `context.messages` (every backend's #to_payload, and
    # the logger) sees it for free — no per-backend plumbing needed.
    def messages
      return @messages unless state_block?

      @messages + [Message.new(:user, @state_block, nil)]
    end

    # True when #messages appends a synthetic trailing user message. Readers
    # of the session log need this to tell the state block apart from
    # something the user actually said — they look identical on the wire, and
    # both are role `user`.
    def state_block? = !(@state_block.nil? || @state_block.to_s.empty?)

    def add_message(role, content, tool_use_id: nil)
      @messages << Message.new(role, content, tool_use_id)
    end

    # Update the known context size from the last API response's input_tokens.
    def update_tokens(n)
      @current_tokens = n.to_i
    end

    # Reset the cumulative per-turn spend counter. Called at the top of a turn.
    def reset_turn_tokens
      @turn_tokens = 0
    end

    # Add one API call's input+output tokens to the cumulative per-turn total.
    # This is the spend budget — distinct from current_tokens (window pressure).
    def add_turn_tokens(input, output)
      @turn_tokens += input.to_i + output.to_i
    end

    # Fraction of the context window currently in use (0.0–1.0).
    def usage_fraction
      @context_window > 0 ? @current_tokens.to_f / @context_window : 0.0
    end

    # Integer percentage (0–100).
    def usage_pct
      (usage_fraction * 100).round
    end

    # True when we should compact before the next API call. Defaults to the
    # configured compaction_threshold (a fraction of context_window).
    def needs_compaction?(threshold: compaction_threshold)
      usage_fraction >= threshold
    end

    # Drop the oldest 40% of messages to free space, keeping at least 2.
    # Resets current_tokens to 0 (will be updated by the next API response).
    # Returns the number of messages dropped.
    def compact_messages!(target_fraction: 0.60)
      drop_count = [(@messages.size * 0.40).ceil, @messages.size - 2].min
      drop_count = [drop_count, 0].max
      @messages = @messages.drop(drop_count)
      @current_tokens = 0
      drop_count
    end

    # Drop all conversation history, keeping tools and system prompt intact.
    def clear_messages!
      @messages = []
      @current_tokens = 0
    end

    def tool_count = @tools.size
    def turn_count = @messages.size

    def to_s
      "#<Context turns=#{turn_count} tools=#{tool_count} window=#{context_window} current=#{current_tokens}>"
    end
  end
end
