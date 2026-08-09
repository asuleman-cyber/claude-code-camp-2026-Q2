require_relative "tasks/planner"
require_relative "tasks/judge"
require_relative "tasks/navigator"
require_relative "tasks/chronicler"
require_relative "player_memory"

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
    def self.build(cfg:, servers:, logger:, ollama_host: "http://localhost:11434", knowledge_store: nil)
      planner   = Tasks::Planner.enabled?(cfg.tasks(Tasks::Planner.task_name))
      judge     = Tasks::Judge.enabled?(cfg.tasks(Tasks::Judge.task_name))
      navigator = Tasks::Navigator.enabled?(cfg.tasks(Tasks::Navigator.task_name))
      memory    = PlayerMemory.build(config: cfg, name: cfg.character_name,
                                     enabled: cfg.memory_enabled?)
      return nil unless planner || judge || navigator || memory

      new(cfg: cfg, servers: servers, logger: logger, ollama_host: ollama_host,
          planner_enabled: planner, judge_enabled: judge, navigator_enabled: navigator,
          knowledge_store: knowledge_store, memory: memory)
    end

    # knowledge_store: an open Mud::Memory::Store, or nil. nil is ordinary,
    # not an error — no `mud` server configured, or sqlite3 not installed
    # (see boukensha_loader.rb). Subagents then simply run without the
    # world_knowledge tool, the same way the Player runs without memory.
    def initialize(cfg:, servers:, logger:, ollama_host: "http://localhost:11434",
                   planner_enabled: false, judge_enabled: false, navigator_enabled: false,
                   knowledge_store: nil, memory: nil)
      @cfg             = cfg
      @servers         = servers
      @logger          = logger
      @ollama_host     = ollama_host
      @planner_enabled = planner_enabled
      @judge_enabled   = judge_enabled
      @navigator_enabled = navigator_enabled
      @knowledge_store = knowledge_store
      @memory          = memory
      @plan            = nil
      @verdict         = nil
      @turns_since_judge = 0
      @unchronicled      = false
    end

    attr_reader :memory

    def memory_enabled? = !@memory.nil?

    # Native tools every subagent gets, as Registry-taking callables.
    #
    # The Player deliberately gets none of this: its room knowledge already
    # arrives for free in the state block Mud::Hooks injects each iteration,
    # and giving it a tool to ask for what it is already being told would be
    # a round trip to learn nothing. Phase H is about the roles that *aren't*
    # standing in the room.
    def native_tools
      return [] unless @knowledge_store

      [->(registry) { Mud::KnowledgeTool.register(registry, store: @knowledge_store) }]
    end

    NAVIGATOR_TOOL = "consult_navigator".freeze

    NAVIGATOR_DESCRIPTION = <<~DESC.strip
      Ask how to travel to a place, when you are not sure where it is or how to reach it. Answers from the map of places already walked; it never looks at the MUD and never moves you — you still have to make the moves yourself.

      Use this when the destination is vague ("a shop", "the temple", "back where the guard was") or when you do not know whether a route exists. If you already know the exact room name and just want the path, world_knowledge with kind=route is cheaper and gives the same answer.

      Returns a direction sequence, or — when no route has been walked yet — the most promising unexplored exit to head for, or a plain "not found".
    DESC

    NAVIGATOR_PARAMETERS = {
      to:   { type: "string", description: "Where you want to get to. A room name, or a description of the sort of place." },
      from: { type: "string", description: "Where to start from. Omit for your current room." }
    }.freeze

    # Register `consult_navigator` on a caller's registry.
    #
    # Called for the Player (in Boukensha.repl) and the Judge (in run_judge).
    # NOT the Planner: Phase G made it toolless on purpose — it plans from the
    # goal and the memory it is given, and finding out what the world looks
    # like is the Player's job.
    #
    # Registration goes through Registry#tool like everything else, so a
    # caller whose `allow:` block omits consult_navigator simply doesn't get
    # it — this method never bypasses the gate.
    def register_navigator_tool(registry)
      return nil unless navigator_enabled?

      registry.tool(NAVIGATOR_TOOL, description: NAVIGATOR_DESCRIPTION, parameters: NAVIGATOR_PARAMETERS) do |to: nil, from: nil|
        navigate(to: to, from: from)
      end
    end

    # Run the Navigator subagent. Returns its answer as a plain string — the
    # caller's context gains exactly one tool_call/tool_result pair, and none
    # of the Navigator's own lookups.
    def navigate(to:, from: nil)
      return "navigator unavailable." unless navigator_enabled?
      return "consult_navigator needs a destination in `to`." if to.to_s.strip.empty?

      @logger.orchestrator(role: "navigator", event: "start", detail: [from, to].compact.join(" -> "))
      answer = run_navigator(to: to, from: from)
      @logger.orchestrator(role: "navigator", event: "answer", detail: nil, text: answer)
      answer
    rescue StandardError => e
      # Degrade to "don't know", never break the caller's turn — the caller
      # asked for directions, not for a reason to stop playing.
      @logger.orchestrator(role: "navigator", event: "error", detail: "#{e.class}: #{e.message}")
      "navigator unavailable (#{e.class}: #{e.message})"
    end

    def planner_enabled?   = @planner_enabled
    def judge_enabled?     = @judge_enabled
    # The Navigator also needs somewhere to navigate: with no knowledge store
    # its only tool doesn't exist, and it would be a model call guaranteed to
    # answer "I don't know."
    def navigator_enabled? = @navigator_enabled && !@knowledge_store.nil?

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

      text = run_planner(goal: goal, player_memory: @memory&.digest)
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

      # A verdict that isn't "carry on" is a natural seam in the session —
      # something concluded, or went wrong, and that is exactly the moment
      # worth remembering. Flushing here rather than only at exit means a
      # session killed mid-play still leaves memory behind.
      flush_memory!(context: context, reason: "verdict:#{@verdict}") if @verdict != :continue

      @verdict
    rescue StandardError => e
      @logger.orchestrator(role: "judge", event: "error", detail: "#{e.class}: #{e.message}")
      @verdict_text = "the judge could not be reached (#{e.class}: #{e.message})"
      @verdict      = :flag
    end

    # Mark that play has happened which the digest doesn't yet reflect. The
    # Repl calls this each turn; #flush_memory! consults it so that repeated
    # boundaries (a :flag verdict, then /exit moments later) don't each pay
    # for a Chronicler call over the same, already-recorded play.
    def note_activity!
      @unchronicled = true if @memory
    end

    # Redistil the digest from the session so far. Returns the new digest, or
    # nil if there was nothing to do.
    #
    # reason: what triggered it — a verdict, /clear, /exit, EOF. Recorded on
    # the raw record so the jsonl says why each rewrite happened.
    def flush_memory!(context:, reason:)
      return nil unless @memory
      return nil unless @unchronicled

      @unchronicled = false
      @logger.orchestrator(role: "chronicler", event: "start", detail: reason)

      digest = run_chronicler(context: context)
      if digest.nil? || digest.strip.empty?
        @logger.orchestrator(role: "chronicler", event: "empty", detail: reason)
        return nil
      end

      @memory.record(kind: "session", reason: reason, session_id: @logger.session_id)
      @memory.write_digest(digest)
      @logger.orchestrator(role: "chronicler", event: "written", detail: reason, text: digest)
      digest
    rescue StandardError => e
      # Losing a session's memory is bad; crashing the exit path that was
      # trying to save it is worse.
      @logger.orchestrator(role: "chronicler", event: "error", detail: "#{e.class}: #{e.message}")
      nil
    end

    private

    # One toolless model call — see Tasks::Chronicler on why zero tools.
    def run_chronicler(context:)
      settings, system, model, backend = Boukensha.task_setup(Tasks::Chronicler, @cfg)
      ctx = Context.new(system: system, context_window: Models.context_window(model))
      ctx.add_message(:user, chronicler_brief(context: context))

      be      = Boukensha.build_backend(backend, model: model,
                                        api_key: Boukensha.api_key_for(backend), ollama_host: @ollama_host)
      builder = PromptBuilder.new(ctx, be)

      response = Client.new(builder).call(
        tools: [], max_output_tokens: Tasks::Chronicler.max_output_tokens(settings)
      )
      parsed = builder.parse_response(response)
      text   = parsed[:content].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
      @logger.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason],
                       task: Tasks::Chronicler, backend: be)
      text
    end

    def chronicler_brief(context:)
      existing = @memory&.digest
      parts    = []
      parts << if existing
                 "The memory as it currently stands:\n\n#{existing}"
               else
                 "This character has no memory yet — you are writing the first digest."
               end
      parts << "The plan this session was working to:\n\n#{@plan}" if @plan
      parts << "What happened this session (oldest first):\n\n#{render_transcript(context)}"
      parts << "Rewrite the memory to account for all of it."
      parts.join("\n\n")
    end

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
    # player_memory: the character's digest, or nil.
    #
    # This is the ONLY path memory takes to the Player. The Player's own
    # prompt and context are untouched by Phase J — it plays from the plan it
    # is given, exactly as it did before. Routing memory through planning
    # rather than into the playing context means it costs one call's tokens
    # at a decision point, instead of riding on every iteration of every turn
    # forever; and it keeps the already-tested Player path stable.
    def run_planner(goal:, player_memory: nil)
      settings, system, model, backend = Boukensha.task_setup(Tasks::Planner, @cfg)
      ctx = Context.new(system: system, context_window: Models.context_window(model))
      ctx.add_message(:user, planner_brief(goal: goal, player_memory: player_memory))

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
                                           context_window: Models.context_window(model),
                                           native_tools: native_tools)
      # The Judge can consult the Navigator about a plan's geography — "is
      # there even a way to the temple from here?" — without doing the map
      # reading itself. Registered after subagent_context so it goes through
      # the same Judge permissions as everything else.
      register_navigator_tool(registry)
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

    # The Navigator's own turn: its own Context, its own Registry, one tool.
    #
    # The servers ARE passed, together with a permissions object that allows
    # only `world_knowledge` — so `tbamud__move` and friends are filtered out
    # by Phase A's gate at registration and genuinely absent, rather than
    # merely omitted by a caller who could later change their mind. The
    # denial is enforced by the same engine that enforces the Judge's, and a
    # test asserts it.
    def run_navigator(to:, from:)
      settings, system, model, backend = Boukensha.task_setup(Tasks::Navigator, @cfg)
      nav_ctx, registry = Boukensha.subagent_context(
        @servers, permissions: Tasks::Navigator.permissions, system: system,
        context_window: Models.context_window(model), native_tools: native_tools
      )
      nav_ctx.add_message(:user, navigator_brief(to: to, from: from))

      be      = Boukensha.build_backend(backend, model: model,
                                        api_key: Boukensha.api_key_for(backend), ollama_host: @ollama_host)
      builder = PromptBuilder.new(nav_ctx, be)

      Agent.new(
        context: nav_ctx, registry: registry, builder: builder,
        client: Client.new(builder), logger: @logger,
        max_iterations:    Tasks::Navigator.max_iterations(settings),
        max_turn_tokens:   @cfg.agent_max_turn_tokens,
        max_output_tokens: Tasks::Navigator.max_output_tokens(settings),
        task: Tasks::Navigator
      ).run
    end

    def planner_brief(goal:, player_memory:)
      return goal.to_s if player_memory.nil? || player_memory.strip.empty?

      "What this character remembers from previous sessions:\n\n#{player_memory.strip}\n\n---\n\nThe goal for this session:\n\n#{goal}"
    end

    def navigator_brief(to:, from:)
      if from.to_s.strip.empty?
        "Where should the character go to reach: #{to}? Start from wherever it is now."
      else
        "Where should the character go to get from #{from} to #{to}?"
      end
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
