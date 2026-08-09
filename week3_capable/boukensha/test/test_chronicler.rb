require_relative "helper"
require "tmpdir"
require "boukensha/player_memory"

# Phase J — the Chronicler and how memory flows through the orchestrator.
# Model calls are stubbed; what's under test is the routing, the flush
# scheduling, and the failure posture.
class TestChronicler < Minitest::Test
  include McpTestHelper

  # ---- zero tools, by design -------------------------------------------

  # Tools and the world map are not memory: world_knowledge already answers
  # "what is there?" accurately and for free, so duplicating it into a prose
  # digest just makes a staler second copy.
  def test_chronicler_has_no_tools_configured
    refute Boukensha::Tasks::Chronicler.respond_to?(:permissions),
           "the Chronicler must not define a tool surface at all"
    assert_equal "chronicler", Boukensha::Tasks::Chronicler.task_name
  end

  def test_chronicler_ships_its_own_prompt
    prompt = Boukensha::Tasks::Chronicler.system_prompt(
      {}, default_prompts_dir: Boukensha::Config::PROMPTS_DIR
    )
    refute_nil prompt
    Boukensha::PlayerMemory::HEADINGS.each { |h| assert_includes prompt, h }
  end

  # ---- config -----------------------------------------------------------

  def test_memory_is_off_by_default
    config_from("") { |cfg| refute cfg.memory_enabled? }
    config_from("memory:\n  enabled: false\n") { |cfg| refute cfg.memory_enabled? }
    config_from("memory:\n  enabled: true\n")  { |cfg| assert cfg.memory_enabled? }
  end

  # The memory file and the character on screen must not be able to drift
  # apart, so the name comes from the same MUD_NAME the daemon logs in with.
  def test_character_name_comes_from_the_mud_server_env
    yaml = <<~YAML
      mcp_servers:
        mud:
          command: x
          env:
            MUD_NAME: Gandalf
    YAML
    config_from(yaml) { |cfg| assert_equal "Gandalf", cfg.character_name }
  end

  def test_an_explicit_character_overrides_the_mud_name
    yaml = <<~YAML
      memory:
        character: Radagast
      mcp_servers:
        mud:
          command: x
          env:
            MUD_NAME: Gandalf
    YAML
    config_from(yaml) { |cfg| assert_equal "Radagast", cfg.character_name }
  end

  def test_no_mud_server_means_no_character_name
    config_from("") { |cfg| assert_nil cfg.character_name }
  end

  # Memory alone is enough to want an orchestrator — chronicling is useful
  # without a planner or judge.
  def test_enabling_only_memory_builds_an_orchestrator
    config_from(memory_yaml) do |cfg|
      orch = Boukensha::Orchestrator.build(cfg: cfg, servers: [], logger: null_logger)
      refute_nil orch
      assert orch.memory_enabled?
      refute orch.planner_enabled?
    end
  end

  def test_no_orchestrator_when_memory_is_off_and_nothing_else_is_on
    config_from("mcp_servers:\n  mud:\n    command: x\n    env:\n      MUD_NAME: Gandalf\n") do |cfg|
      assert_nil Boukensha::Orchestrator.build(cfg: cfg, servers: [], logger: null_logger)
    end
  end

  # ---- memory reaches the Player ONLY through the Planner ---------------

  def test_the_digest_is_passed_to_the_planner
    with_orchestrator do |orch, mem|
      mem.write_digest("## Open threads\nFind the guild.")
      seen = nil
      orch.define_singleton_method(:run_planner) { |goal:, player_memory: nil| seen = player_memory; "a plan" }

      orch.plan!(goal: "explore", context: Boukensha::Context.new(system: "base"))
      assert_includes seen.to_s, "Find the guild."
    end
  end

  def test_no_digest_means_the_planner_gets_nil
    with_orchestrator do |orch, _mem|
      seen = :unset
      orch.define_singleton_method(:run_planner) { |goal:, player_memory: nil| seen = player_memory; "a plan" }

      orch.plan!(goal: "explore", context: Boukensha::Context.new(system: "base"))
      assert_nil seen
    end
  end

  # The Player's own prompt and context stay untouched by Phase J — it plays
  # from the plan it is given, exactly as before.
  def test_memory_never_enters_the_players_context_directly
    with_orchestrator do |orch, mem|
      mem.write_digest("## Mistakes\nDied to the pit fiend.")
      orch.define_singleton_method(:run_planner) { |goal:, player_memory: nil| "1. go north" }

      ctx = Boukensha::Context.new(system: "player prompt")
      orch.plan!(goal: "explore", context: ctx)

      assert_includes ctx.system, "1. go north"
      refute_includes ctx.system, "pit fiend"
      assert_empty ctx.messages
    end
  end

  # ---- flush scheduling -------------------------------------------------

  def test_flush_is_a_no_op_when_nothing_has_happened
    with_orchestrator do |orch, _mem|
      orch.define_singleton_method(:run_chronicler) { |context:| flunk("should not have been called") }
      assert_nil orch.flush_memory!(context: ctx, reason: "exit")
    end
  end

  def test_flush_writes_the_digest_after_activity
    with_orchestrator do |orch, mem|
      orch.define_singleton_method(:run_chronicler) { |context:| "## Discoveries\nThe temple is north." }
      orch.note_activity!

      digest = orch.flush_memory!(context: ctx, reason: "exit")
      assert_includes digest, "The temple is north."
      assert_includes mem.digest, "The temple is north."
    end
  end

  # A :flag verdict then /exit moments later must not pay for two Chronicler
  # calls over the same play.
  def test_a_second_flush_without_new_activity_is_skipped
    with_orchestrator do |orch, _mem|
      calls = 0
      orch.define_singleton_method(:run_chronicler) { |context:| calls += 1; "digest #{calls}" }
      orch.note_activity!

      orch.flush_memory!(context: ctx, reason: "verdict:flag")
      orch.flush_memory!(context: ctx, reason: "exit")

      assert_equal 1, calls
    end
  end

  def test_activity_after_a_flush_allows_another
    with_orchestrator do |orch, _mem|
      calls = 0
      orch.define_singleton_method(:run_chronicler) { |context:| calls += 1; "digest" }

      orch.note_activity!
      orch.flush_memory!(context: ctx, reason: "one")
      orch.note_activity!
      orch.flush_memory!(context: ctx, reason: "two")

      assert_equal 2, calls
    end
  end

  def test_an_empty_chronicler_reply_leaves_the_old_digest_alone
    with_orchestrator do |orch, mem|
      mem.write_digest("previous memory")
      orch.define_singleton_method(:run_chronicler) { |context:| "   " }
      orch.note_activity!

      assert_nil orch.flush_memory!(context: ctx, reason: "exit")
      assert_includes mem.digest, "previous memory"
    end
  end

  # Losing a session's memory is bad; crashing the exit path that was trying
  # to save it is worse.
  def test_a_failing_chronicler_returns_nil_instead_of_raising
    with_orchestrator do |orch, mem|
      mem.write_digest("previous memory")
      orch.define_singleton_method(:run_chronicler) { |context:| raise(Boukensha::ApiError, "boom") }
      orch.note_activity!

      assert_nil orch.flush_memory!(context: ctx, reason: "exit")
      assert_includes mem.digest, "previous memory"
    end
  end

  def test_flush_is_a_no_op_when_memory_is_disabled
    config_from("tasks:\n  judge:\n    provider: anthropic\n    model: claude-haiku-4-5\n") do |cfg|
      orch = Boukensha::Orchestrator.new(cfg: cfg, servers: [], logger: null_logger, judge_enabled: true)
      refute orch.memory_enabled?
      orch.note_activity!
      assert_nil orch.flush_memory!(context: ctx, reason: "exit")
    end
  end

  private

  def ctx
    @ctx ||= begin
      c = Boukensha::Context.new(system: "base")
      c.add_message(:user, "go north")
      c.add_message(:assistant, "I moved north.")
      c
    end
  end

  def memory_yaml
    <<~YAML
      memory:
        enabled: true
      mcp_servers:
        mud:
          command: x
          env:
            MUD_NAME: Gandalf
    YAML
  end

  def with_orchestrator
    config_from(memory_yaml) do |cfg|
      mem  = Boukensha::PlayerMemory.build(config: cfg, name: cfg.character_name, enabled: true)
      orch = Boukensha::Orchestrator.new(cfg: cfg, servers: [], logger: null_logger,
                                         planner_enabled: true, memory: mem)
      yield orch, mem
    end
  end

  def null_logger
    Object.new.tap do |o|
      def o.plan(**)         = nil
      def o.orchestrator(**) = nil
      def o.response(**)     = nil
      def o.session_id       = "test-session"
    end
  end
end
