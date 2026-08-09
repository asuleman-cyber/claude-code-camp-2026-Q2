require_relative "helper"

class TestRegistry < Minitest::Test
  def new_context
    Boukensha::Context.new(system: "test")
  end

  # Regression guard: every existing test constructs Registry.new(ctx) with
  # no permissions: and must keep behaving exactly as before — permissive,
  # every tool registers and dispatches.
  def test_default_registry_is_fully_permissive
    ctx = new_context
    registry = Boukensha::Registry.new(ctx)

    tool = registry.tool("move", description: "move") { |**_| "moved" }
    refute_nil tool
    assert_includes registry.tool_names, "move"
    assert_equal "moved", registry.dispatch("move", {})
  end

  def test_tool_returns_nil_and_does_not_register_when_disallowed
    ctx = new_context
    perms = Boukensha::Permissions.new(["move"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)

    result = registry.tool("attack", description: "attack") { |**_| "hit" }

    assert_nil result
    refute_includes registry.tool_names, "attack"
  end

  def test_allowed_tool_still_registers_under_a_restrictive_permissions
    ctx = new_context
    perms = Boukensha::Permissions.new(["move"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)

    registry.tool("move", description: "move") { |**_| "moved" }

    assert_includes registry.tool_names, "move"
    assert_equal "moved", registry.dispatch("move", {})
  end

  def test_dispatch_raises_unauthorized_for_a_disallowed_value
    ctx = new_context
    perms = Boukensha::Permissions.new(["check(kind: score)"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)
    registry.tool("check", description: "check") { |**kwargs| "checked #{kwargs[:kind]}" }

    assert_equal "checked score", registry.dispatch("check", "kind" => "score")
    assert_raises(Boukensha::UnauthorizedToolError) { registry.dispatch("check", "kind" => "exits") }
  end

  def test_dispatch_raises_unknown_tool_for_a_name_never_registered
    ctx = new_context
    registry = Boukensha::Registry.new(ctx)
    assert_raises(Boukensha::UnknownToolError) { registry.dispatch("nope", {}) }
  end
end
