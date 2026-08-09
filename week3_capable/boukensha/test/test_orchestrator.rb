require_relative "helper"

# Phase G — the Planner/Judge orchestrator.
#
# Everything here is offline: no model call, no MUD. The parts that need a
# real MCP server (the Judge's read-only tool surface, sharing the Player's
# connection) are covered in test_mcp_servers_config.rb, which has one.
class TestOrchestrator < Minitest::Test
  include McpTestHelper

  # ---- Context#plan ---------------------------------------------------
  # The plan rides in the system prompt so compaction cannot eat it. These
  # tests are the guarantee behind that claim.

  def test_system_is_unchanged_when_there_is_no_plan
    ctx = Boukensha::Context.new(system: "base prompt")
    assert_equal "base prompt", ctx.system
    assert_equal "base prompt", ctx.effective_system
    assert_nil ctx.plan
  end

  def test_plan_is_appended_to_the_system_prompt
    ctx = Boukensha::Context.new(system: "base prompt")
    ctx.plan = "1. go north"

    assert_includes ctx.system, "base prompt"
    assert_includes ctx.system, "1. go north"
    assert_includes ctx.system, Boukensha::Context::PLAN_HEADING
    # base_system stays clean, so re-planning can't compound.
    assert_equal "base prompt", ctx.base_system
  end

  def test_replanning_replaces_rather_than_accumulates
    ctx = Boukensha::Context.new(system: "base")
    ctx.plan = "first plan"
    ctx.plan = "second plan"

    assert_includes ctx.system, "second plan"
    refute_includes ctx.system, "first plan"
    assert_equal 1, ctx.system.scan(Boukensha::Context::PLAN_HEADING).size
  end

  def test_a_blank_plan_is_treated_as_no_plan
    ctx = Boukensha::Context.new(system: "base")
    ctx.plan = "   \n "
    assert_equal "base", ctx.system
  end

  # The whole reason the plan lives in the system prompt: compaction drops
  # the oldest messages, and a plan delivered as a message would go with them.
  def test_the_plan_survives_compaction
    ctx = Boukensha::Context.new(system: "base")
    ctx.plan = "the objective"
    20.times { |i| ctx.add_message(:user, "message #{i}") }

    dropped = ctx.compact_messages!

    assert_operator dropped, :>, 0, "expected compaction to actually drop messages"
    assert_includes ctx.system, "the objective"
  end

  # ---- Judge verdict parsing -------------------------------------------

  def test_parses_each_verdict
    assert_equal :continue, Boukensha::Tasks::Judge.parse_verdict("all fine\nVERDICT: continue")
    assert_equal :replan,   Boukensha::Tasks::Judge.parse_verdict("done\nVERDICT: replan")
    assert_equal :flag,     Boukensha::Tasks::Judge.parse_verdict("stuck\nVERDICT: flag")
  end

  def test_verdict_parsing_is_case_and_space_insensitive
    assert_equal :continue, Boukensha::Tasks::Judge.parse_verdict("VERDICT:continue")
    assert_equal :replan,   Boukensha::Tasks::Judge.parse_verdict("  verdict:   REPLAN  ")
  end

  # Fails closed, deliberately: a judge we can't read is not a judge saying
  # "carry on".
  def test_unreadable_verdict_is_flag
    assert_equal :flag, Boukensha::Tasks::Judge.parse_verdict("I think it's going well!")
    assert_equal :flag, Boukensha::Tasks::Judge.parse_verdict("")
    assert_equal :flag, Boukensha::Tasks::Judge.parse_verdict(nil)
    assert_equal :flag, Boukensha::Tasks::Judge.parse_verdict("VERDICT: maybe")
  end

  # A verdict word used mid-sentence must not beat the real trailing line.
  def test_the_last_verdict_line_wins
    text = "This is not a replan situation.\nVERDICT: continue"
    assert_equal :continue, Boukensha::Tasks::Judge.parse_verdict(text)
  end

  # ---- Judge tool surface ----------------------------------------------

  def test_judge_permissions_allow_only_observation
    perms = Boukensha::Tasks::Judge.permissions

    %w[look examine check consider inspect poll mud_status].each do |t|
      assert perms.allow_tool?(t), "#{t} should be allowed"
      assert perms.allow_tool?("tbamud__#{t}"), "tbamud__#{t} should be allowed"
    end

    %w[move flee attack skill_strike set_position get_item drop_item
       cast_spell shop practice save_character send_raw tell].each do |t|
      refute perms.allow_tool?(t),             "#{t} must be denied"
      refute perms.allow_tool?("tbamud__#{t}"), "tbamud__#{t} must be denied"
    end
  end

  # send_raw would make every other rule decorative — it can run any command.
  def test_judge_cannot_reach_the_raw_escape_hatch
    refute Boukensha::Tasks::Judge.permissions.allow_tool?("send_raw")
  end

  # ---- enabled? / build -------------------------------------------------

  def test_tasks_are_off_unless_settings_say_otherwise
    refute Boukensha::Tasks::Planner.enabled?(nil)
    refute Boukensha::Tasks::Planner.enabled?({})
    refute Boukensha::Tasks::Judge.enabled?({ "model" => "x" })

    assert Boukensha::Tasks::Planner.enabled?({ "enabled" => true })
    assert Boukensha::Tasks::Planner.enabled?({ "enabled" => "yes" })
    refute Boukensha::Tasks::Planner.enabled?({ "enabled" => false })
  end

  # A settings.yaml written before Phase G must behave exactly as it did.
  def test_build_returns_nil_when_nothing_is_enabled
    config_from("tasks:\n  player:\n    provider: anthropic\n    model: claude-haiku-4-5\n") do |cfg|
      assert_nil Boukensha::Orchestrator.build(cfg: cfg, servers: [], logger: null_logger)
    end
  end

  def test_build_returns_an_orchestrator_when_a_role_is_enabled
    config_from(<<~YAML) do |cfg|
      tasks:
        planner:
          provider: anthropic
          model: claude-haiku-4-5
          enabled: true
    YAML
      orch = Boukensha::Orchestrator.build(cfg: cfg, servers: [], logger: null_logger)
      refute_nil orch
      assert orch.planner_enabled?
      refute orch.judge_enabled?
    end
  end

  # ---- default prompts --------------------------------------------------
  # PROMPTS_DIR was `../../../prompts` through Week 2 — one `..` too many, so
  # it pointed at the gem root's parent and the packaged prompts were never
  # read. The player never noticed because settings.yaml gives it a user
  # override; Planner and Judge have none, so they booted promptless.

  def test_the_packaged_prompts_directory_actually_exists
    assert Dir.exist?(Boukensha::Config::PROMPTS_DIR),
           "PROMPTS_DIR (#{Boukensha::Config::PROMPTS_DIR}) must resolve to the gem's prompts/"
  end

  def test_each_task_resolves_its_own_default_prompt
    dir     = Boukensha::Config::PROMPTS_DIR
    player  = Boukensha::Tasks::Player.system_prompt({},  default_prompts_dir: dir)
    planner = Boukensha::Tasks::Planner.system_prompt({}, default_prompts_dir: dir)
    judge   = Boukensha::Tasks::Judge.system_prompt({},   default_prompts_dir: dir)

    refute_nil player
    assert_includes planner, "Planner"
    assert_includes judge,   "Judge"
    assert_equal 3, [player, planner, judge].uniq.size, "each task needs its own prompt"
  end

  # player has no prompts/player/ subdirectory, so it must still read the
  # shared prompts/system.md it has always read.
  def test_player_falls_back_to_the_shared_prompt
    dir = Boukensha::Config::PROMPTS_DIR
    assert_equal File.read(File.join(dir, "system.md")).strip,
                 Boukensha::Tasks::Player.system_prompt({}, default_prompts_dir: dir)
  end

  # ---- judge scheduling -------------------------------------------------

  def test_judge_is_not_due_when_disabled
    orch = build_orchestrator(judge_enabled: false)
    refute orch.judge_due?(:completed)
  end

  def test_judge_runs_every_turn_by_default
    orch = build_orchestrator(judge_enabled: true)
    assert orch.judge_due?(:completed)
  end

  # A turn cut off by a limit is exactly what a checkpoint is for, so it
  # jumps the queue regardless of the interval.
  def test_a_tripped_limit_forces_a_judgement
    orch = build_orchestrator(judge_enabled: true, yaml_extra: "    every: 5\n")
    assert orch.judge_due?(:max_iterations)
    assert orch.judge_due?(:max_tokens)
  end

  def test_every_n_spaces_out_judgements
    orch = build_orchestrator(judge_enabled: true, yaml_extra: "    every: 3\n")
    assert_equal 3, orch.judge_every

    refute orch.judge_due?(:completed)   # turn 1
    refute orch.judge_due?(:completed)   # turn 2
    assert orch.judge_due?(:completed)   # turn 3
  end

  # ---- Phase H: the knowledge tool reaches subagents ---------------------

  def test_no_knowledge_store_means_no_native_tools
    assert_empty build_orchestrator(judge_enabled: true).native_tools
  end

  def test_a_knowledge_store_produces_the_world_knowledge_tool
    require "boukensha/mud/memory/store"
    require "boukensha/mud/knowledge_tool"
    store = Boukensha::Mud::Memory::Store.new(":memory:")

    orch = build_orchestrator(judge_enabled: true, knowledge_store: store)
    ctx      = Boukensha::Context.new(system: "t")
    registry = Boukensha::Registry.new(ctx, permissions: Boukensha::Tasks::Judge.permissions)
    orch.native_tools.each { |t| t.call(registry) }

    assert_includes registry.tool_names, "world_knowledge"
  ensure
    store&.close
  end

  # The Player is deliberately excluded: its room knowledge already arrives
  # in the state block Mud::Hooks injects every iteration, so a tool to ask
  # for it would be a round trip to learn what it was just told. Its registry
  # is built from settings.yaml's mcp_servers alone — native_tools is a
  # subagent-only path — so the tool must be absent even with a store open.
  def test_the_player_does_not_get_the_knowledge_tool
    require "boukensha/mud/memory/store"
    store = Boukensha::Mud::Memory::Store.new(":memory:")
    build_orchestrator(judge_enabled: true, knowledge_store: store)

    ctx    = Boukensha::Context.new(system: "player")
    player = Boukensha::Registry.new(ctx) # permissive, as the player's is
    refute_includes player.tool_names, "world_knowledge"
  ensure
    store&.close
  end

  # ---- failure handling -------------------------------------------------

  # The orchestrator is an addition to a working agent. If planning breaks,
  # the agent should play unplanned, not die.
  def test_a_failing_planner_returns_nil_and_leaves_the_context_alone
    orch = build_orchestrator(planner_enabled: true)
    ctx  = Boukensha::Context.new(system: "base")

    # No API key / no network: run_planner will raise inside plan!.
    def orch.run_planner(goal:) = raise(Boukensha::ApiError, "boom")

    assert_nil orch.plan!(goal: "explore", context: ctx)
    assert_nil ctx.plan
    assert_equal "base", ctx.system
  end

  # Fails closed for the same reason an unparseable verdict does.
  def test_a_failing_judge_flags
    orch = build_orchestrator(judge_enabled: true)
    def orch.run_judge(context:, stop_reason:) = raise(Boukensha::ApiError, "boom")

    assert_equal :flag, orch.judge!(context: Boukensha::Context.new(system: "base"))
    assert_match(/could not be reached/, orch.verdict_text)
  end

  def test_a_successful_plan_is_installed_on_the_context
    orch = build_orchestrator(planner_enabled: true)
    ctx  = Boukensha::Context.new(system: "base")
    def orch.run_planner(goal:) = "1. go north\n2. look"

    assert_equal "1. go north\n2. look", orch.plan!(goal: "explore", context: ctx)
    assert_includes ctx.system, "1. go north"
  end

  def test_verdict_text_drops_the_machine_readable_line
    orch = build_orchestrator(judge_enabled: true)
    def orch.run_judge(context:, stop_reason:) = "The character is stuck.\nVERDICT: flag"

    assert_equal :flag, orch.judge!(context: Boukensha::Context.new(system: "base"))
    assert_equal "The character is stuck.", orch.verdict_text
  end

  private

  def null_logger
    Object.new.tap do |o|
      def o.plan(**)         = nil
      def o.orchestrator(**) = nil
      def o.response(**)     = nil
    end
  end

  def build_orchestrator(planner_enabled: false, judge_enabled: false, yaml_extra: nil, knowledge_store: nil)
    yaml = +"tasks:\n  judge:\n    provider: anthropic\n    model: claude-haiku-4-5\n"
    yaml << yaml_extra if yaml_extra
    config_from(yaml) do |cfg|
      return Boukensha::Orchestrator.new(
        cfg: cfg, servers: [], logger: null_logger,
        planner_enabled: planner_enabled, judge_enabled: judge_enabled,
        knowledge_store: knowledge_store
      )
    end
  end
end
