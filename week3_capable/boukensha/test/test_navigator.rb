require_relative "helper"
require "boukensha/mud/memory/store"
require "boukensha/mud/knowledge_tool"

# Phase I — the Navigator subagent and its `consult_navigator` tool.
#
# The model call is stubbed throughout; what's under test is the tool
# surface, the isolation, the enablement rules, and the failure posture.
class TestNavigator < Minitest::Test
  include McpTestHelper

  # ---- tool surface -----------------------------------------------------

  # The Navigator answers whether a path exists; it never walks it. That's an
  # allowlist, not a convention — every MUD tool is absent, not merely unused.
  def test_navigator_may_only_read_the_map
    perms = Boukensha::Tasks::Navigator.permissions

    assert perms.allow_tool?("world_knowledge")

    %w[move flee look inspect attack send_raw get_item set_position].each do |t|
      refute perms.allow_tool?(t),              "#{t} must be denied"
      refute perms.allow_tool?("tbamud__#{t}"), "tbamud__#{t} must be denied"
    end
  end

  # Explicitly the two the plan calls out — it answers "is there a path",
  # never "let me go and look".
  def test_navigator_cannot_move_or_look
    perms = Boukensha::Tasks::Navigator.permissions
    refute perms.allow_tool?("tbamud__move")
    refute perms.allow_tool?("tbamud__look")
  end

  def test_navigator_is_bounded
    assert_equal 4, Boukensha::Tasks::Navigator.max_iterations({})
    assert_equal 2, Boukensha::Tasks::Navigator.max_iterations({ "max_iterations" => 2 })
  end

  # ---- enablement -------------------------------------------------------

  def test_navigator_is_off_by_default
    refute Boukensha::Tasks::Navigator.enabled?({})
    refute Boukensha::Tasks::Navigator.enabled?(nil)
    assert Boukensha::Tasks::Navigator.enabled?({ "enabled" => true })
  end

  # Enabling it alone is enough to get an orchestrator, even with no
  # planner/judge — consult_navigator is useful on its own.
  def test_enabling_only_the_navigator_still_builds_an_orchestrator
    with_store do |store|
      config_from(navigator_yaml) do |cfg|
        orch = Boukensha::Orchestrator.build(cfg: cfg, servers: [], logger: null_logger,
                                             knowledge_store: store)
        refute_nil orch
        assert orch.navigator_enabled?
        refute orch.planner_enabled?
      end
    end
  end

  # Without a knowledge store its only tool doesn't exist, so it would be a
  # model call guaranteed to answer "I don't know".
  def test_navigator_is_disabled_without_a_knowledge_store
    config_from(navigator_yaml) do |cfg|
      orch = Boukensha::Orchestrator.build(cfg: cfg, servers: [], logger: null_logger,
                                           knowledge_store: nil)
      refute orch.navigator_enabled?
    end
  end

  # ---- registration -----------------------------------------------------

  def test_registers_consult_navigator_on_a_callers_registry
    with_orchestrator do |orch|
      registry = permissive_registry
      orch.register_navigator_tool(registry)

      assert_includes registry.tool_names, "consult_navigator"
    end
  end

  def test_registers_nothing_when_disabled
    with_store do |store|
      config_from("tasks:\n  navigator:\n    provider: anthropic\n    model: claude-haiku-4-5\n    enabled: false\n") do |cfg|
        orch = Boukensha::Orchestrator.new(cfg: cfg, servers: [], logger: null_logger,
                                           navigator_enabled: false, knowledge_store: store)
        registry = permissive_registry
        assert_nil orch.register_navigator_tool(registry)
        refute_includes registry.tool_names, "consult_navigator"
      end
    end
  end

  # Registration goes through Registry#tool like everything else, so a
  # caller whose allow: block omits the tool simply doesn't get it.
  def test_a_restrictive_caller_does_not_get_the_tool
    with_orchestrator do |orch|
      ctx      = Boukensha::Context.new(system: "t")
      registry = Boukensha::Registry.new(ctx, permissions: Boukensha::Permissions.new(%w[look]))
      orch.register_navigator_tool(registry)

      refute_includes registry.tool_names, "consult_navigator"
    end
  end

  # The Judge is allowed to consult it about a plan's geography.
  def test_the_judge_may_consult_the_navigator
    assert Boukensha::Tasks::Judge.permissions.allow_tool?("consult_navigator")
  end

  # ---- dispatch behaviour -----------------------------------------------

  def test_dispatch_requires_a_destination
    with_orchestrator do |orch|
      registry = permissive_registry
      orch.register_navigator_tool(registry)

      assert_includes registry.dispatch("consult_navigator", { "to" => "" }), "needs a destination"
    end
  end

  def test_dispatch_returns_the_navigators_answer
    with_orchestrator do |orch|
      def orch.run_navigator(to:, from:) = "north, east — 2 steps."
      registry = permissive_registry
      orch.register_navigator_tool(registry)

      assert_equal "north, east — 2 steps.", registry.dispatch("consult_navigator", { "to" => "Market" })
    end
  end

  def test_the_from_argument_is_optional
    with_orchestrator do |orch|
      seen = nil
      orch.define_singleton_method(:run_navigator) { |to:, from:| seen = [to, from]; "ok" }
      registry = permissive_registry
      orch.register_navigator_tool(registry)

      registry.dispatch("consult_navigator", { "to" => "Market" })
      assert_equal ["Market", nil], seen
    end
  end

  # A broken navigator must not take down the turn that asked it for
  # directions — the caller wanted a route, not a reason to stop playing.
  def test_a_failing_navigator_degrades_instead_of_raising
    with_orchestrator do |orch|
      def orch.run_navigator(to:, from:) = raise(Boukensha::ApiError, "boom")
      registry = permissive_registry
      orch.register_navigator_tool(registry)

      result = registry.dispatch("consult_navigator", { "to" => "Market" })
      assert_includes result, "navigator unavailable"
      assert_includes result, "boom"
    end
  end

  # ---- isolation --------------------------------------------------------

  # The caller's context gains exactly one tool_call/tool_result pair and
  # none of the Navigator's own lookups — which is what a native tool gives
  # us for free, so this pins that it stays that way.
  def test_the_navigator_does_not_touch_the_callers_context
    with_orchestrator do |orch|
      def orch.run_navigator(to:, from:) = "north."
      ctx      = Boukensha::Context.new(system: "caller")
      registry = Boukensha::Registry.new(ctx)
      orch.register_navigator_tool(registry)

      ctx.add_message(:user, "where is the temple?")
      before = ctx.messages.size
      registry.dispatch("consult_navigator", { "to" => "Temple" })

      assert_equal before, ctx.messages.size, "navigator must not append to the caller's history"
    end
  end

  private

  def navigator_yaml
    "tasks:\n  navigator:\n    provider: anthropic\n    model: claude-haiku-4-5\n    enabled: true\n"
  end

  def permissive_registry
    Boukensha::Registry.new(Boukensha::Context.new(system: "t"))
  end

  def with_store
    store = Boukensha::Mud::Memory::Store.new(":memory:")
    yield store
  ensure
    store&.close
  end

  def with_orchestrator
    with_store do |store|
      config_from(navigator_yaml) do |cfg|
        yield Boukensha::Orchestrator.new(
          cfg: cfg, servers: [], logger: null_logger,
          navigator_enabled: true, knowledge_store: store
        )
      end
    end
  end

  def null_logger
    Object.new.tap do |o|
      def o.plan(**)         = nil
      def o.orchestrator(**) = nil
      def o.response(**)     = nil
    end
  end
end
