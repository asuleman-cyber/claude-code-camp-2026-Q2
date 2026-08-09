require_relative "tasks/planner"
require_relative "tasks/judge"

module Boukensha
  # Orchestrator wraps the Player turn loop with the two other model roles:
  # a Planner that decides what to aim at before play starts, and a Judge
  # that checkpoints afterwards and says continue / replan / flag.
  #
  # It owns no MUD connection of its own. Both subagents run against the MCP
  # clients the Player already opened (see Boukensha.subagent_context), each
  # in a throwaway Context so nothing they say enters the Player's history.
  #
  # Both roles are off unless settings.yaml switches them on:
  #
  #   tasks:
  #     planner:
  #       provider: anthropic
  #       model:    claude-haiku-4-5
  #       enabled:  true
  #     judge:
  #       provider: anthropic
  #       model:    claude-haiku-4-5
  #       enabled:  true
  #       every:    3        # judge after every Nth player turn (default 1)
  #
  # With neither block present, .build returns nil and every call site falls
  # back to plain single-agent behaviour — a settings.yaml written before
  # Phase G runs exactly as it did before.
  class Orchestrator
    DEFAULT_JUDGE_EVERY = 1

    # verdict: the last :continue/:replan/:flag. verdict_text: the Judge's own
    # reasoning behind it, which is what a human actually needs to see when a
    # :flag comes back.
    attr_reader :verdict, :verdict_text, :plan

    # nil unless at least one role is enabled — so callers can treat "no
    # orchestrator" and "orchestrator with nothing switched on" identically.
    def self.build(cfg:, servers:, logger:, ollama_host: "http://localhost:11434")
      planner = Tasks::Planner.enabled?(cfg.tasks(Tasks::Planner.task_name))
      judge   = Tasks::Judge.enabled?(cfg.tasks(Tasks::Judge.task_name))
      return nil unless planner || judge

      new(cfg: cfg, servers: servers, logger: logger, ollama_host: ollama_host,
          planner_enabled: planner, judge_enabled: judge)
    end

    def initialize(cfg:, servers:, logger:, ollama_host: "http://localhost:11434",
                   planner_enabled: false, judge_enabled: false)
      @cfg             = cfg
      @servers         = servers
      @logger          = logger
      @ollama_host     = ollama_host
      @planner_enabled = planner_enabled
      @judge_enabled   = judge_enabled
      @plan            = nil
      @verdict         = nil
      @turns_since_judge = 0
    end

    def planner_enabled? = @planner_enabled
    def judge_enabled?   = @judge_enabled

    # How many player turns between judgements (settings: tasks.judge.every).
    def judge_every
      raw = setting(Tasks::Judge, :every)
      value = raw.nil? ? DEFAULT_JUDGE_EVERY : Integer(raw)
      value.positive? ? value : DEFAULT_JUDGE_EVERY
    end

    # Write a plan for `goal` and install it on `context`.
    #
    # One model call, no loop, no tools — see Tasks::Planner. Returns the plan
    # text, or nil if planning is off or the call failed. A failed plan is
    # never fatal: the Player is perfectly able to play unplanned, and taking
    # the whole session down because the optional planning step 500'd would
    # make the orchestrator strictly worse than not having one.
    def plan!(goal:, context:)
      return nil unless @planner_enabled

      text = run_planner(goal: goal)
      return nil if text.nil? || text.strip.empty?

      @plan = text.strip
      context.plan = @plan
      @logger.plan(text: @plan)
      @plan
    rescue StandardError => e
      @logger.orchestrator(role: "planner", event: "error", detail: "#{e.class}: #{e.message}")
      nil
    end

    # Should the Judge run after this player turn?
    #
    # Always after a turn that hit a limit — being cut off mid-task is exactly
    # the case a checkpoint exists for — otherwise every judge_every turns.
    def judge_due?(stop_reason)
      return false unless @judge_enabled

      @turns_since_judge += 1
      return true if stop_reason && stop_reason != :completed
      return false if @turns_since_judge < judge_every

      true
    end

    # Run the Judge over what the Player just did. Returns a verdict symbol
    # (:continue / :replan / :flag) and records it on #verdict.
    #
    # A Judge that errors returns :flag, for the same reason an unparseable
    # verdict does (Tasks::Judge.parse_verdict): the checkpoint failing open
    # would let an unsupervised agent keep running precisely when supervision
    # broke.
    def judge!(context:, stop_reason: nil)
      return nil unless @judge_enabled

      @turns_since_judge = 0
      text         = run_judge(context: context, stop_reason: stop_reason)
      @verdict_text = strip_verdict_line(text)
      @verdict      = Tasks::Judge.parse_verdict(text)
      @logger.orchestrator(role: "judge", event: "verdict", detail: @verdict.to_s, text: text)
      @verdict
    rescue StandardError => e
      @logger.orchestrator(role: "judge", event: "error", detail: "#{e.class}: #{e.message}")
      @verdict_text = "the judge could not be reached (#{e.class}: #{e.message})"
      @verdict      = :flag
    end

    private

    # The Judge's reasoning without the machine-readable verdict line — that
    # part is already reported as the verdict itself, and repeating it back at
    # a human reads like stutter.
    def strip_verdict_line(text)
      text.to_s.lines.reject { |l| Tasks::Judge::VERDICT_PATTERN.match?(l) }.join.strip
    end

    def setting(task_class, key)
      s = @cfg.tasks(task_class.task_name)
      s.is_a?(Hash) ? (s[key.to_s].nil? ? s[key.to_sym] : s[key.to_s]) : nil
    end

    # One toolless model call. Not an Agent#run: with no tools there is
    # nothing to iterate over, and a loop would only add the possibility of
    # spending more than one call's worth of tokens on a paragraph of prose.
    def run_planner(goal:)
      settings, system, model, backend = Boukensha.task_setup(Tasks::Planner, @cfg)
      ctx = Context.new(system: system, context_window: Models.context_window(model))
      ctx.add_message(:user, goal.to_s)

      be      = Boukensha.build_backend(backend, model: model,
                               api_key: Boukensha.api_key_for(backend), ollama_host: @ollama_host)
      builder = PromptBuilder.new(ctx, be)
      @logger.orchestrator(role: "planner", event: "start", detail: goal.to_s)

      response = Client.new(builder).call(
        tools: [], max_output_tokens: Tasks::Planner.max_output_tokens(settings)
      )
      parsed = builder.parse_response(response)
      text   = parsed[:content].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
      @logger.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason],
                       task: Tasks::Planner, backend: be)
      text
    end

    # A small Agent#run against a throwaway Context with a read-only tool
    # surface. The Judge sees a rendered transcript of the Player's turn as
    # its user message — not the Player's Context object — so there is no way
    # for it to append to, compact, or otherwise disturb the live history.
    def run_judge(context:, stop_reason:)
      settings, system, model, backend = Boukensha.task_setup(Tasks::Judge, @cfg)
      perms       = Tasks::Judge.permissions
      judge_ctx, registry = Boukensha.subagent_context(@servers,
                                           permissions: perms, system: system,
                                           context_window: Models.context_window(model))
      judge_ctx.add_message(:user, judge_brief(context: context, stop_reason: stop_reason))

      be      = Boukensha.build_backend(backend, model: model,
                               api_key: Boukensha.api_key_for(backend), ollama_host: @ollama_host)
      builder = PromptBuilder.new(judge_ctx, be)
      @logger.orchestrator(role: "judge", event: "start", detail: stop_reason.to_s)

      Agent.new(
        context: judge_ctx, registry: registry, builder: builder,
        client: Client.new(builder), logger: @logger,
        max_iterations:    Tasks::Judge.max_iterations(settings),
        max_turn_tokens:   @cfg.agent_max_turn_tokens,
        max_output_tokens: Tasks::Judge.max_output_tokens(settings),
        task: Tasks::Judge
      ).run
    end

    # What the Judge is shown: the plan in force, how the turn ended, and the
    # tail of the Player's conversation.
    TRANSCRIPT_MESSAGES = 12
    TRANSCRIPT_CHARS    = 600

    def judge_brief(context:, stop_reason:)
      lines = []
      lines << "The plan the Player was given:\n\n#{@plan}" if @plan
      lines << "The Player's turn ended with: #{stop_reason || "completed"}"
      lines << "Recent transcript (oldest first):\n\n#{render_transcript(context)}"
      lines.join("\n\n")
    end

    def render_transcript(context)
      context.messages.last(TRANSCRIPT_MESSAGES).map do |m|
        body = case m.content
               when String then m.content
               when Array  then m.content.map { |b| b.is_a?(Hash) ? (b["text"] || b["name"] || b["type"]) : b.to_s }.join(" ")
               else m.content.to_s
               end
        body = body.to_s.strip
        body = "#{body[0, TRANSCRIPT_CHARS]}…" if body.length > TRANSCRIPT_CHARS
        "[#{m.role}] #{body}"
      end.join("\n")
    end
  end
end
