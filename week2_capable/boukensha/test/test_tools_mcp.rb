require_relative "helper"

# Boukensha::Tools::Mcp is the generic MCP host layer: point it at any MCP
# server and that server's tools become boukensha tools. These tests use the
# mud-manager daemon as "some MCP server" and deliberately never rely on it
# being a MUD.
class TestToolsMcp < Minitest::Test
  include McpTestHelper

  def setup
    @fake = start_fake_mud
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  def register(registry, prefix: nil, permissions: nil)
    @client = Boukensha::Tools::Mcp.register(
      registry, command: mud_manager_command, args: mud_manager_args,
                env: fake_mud_env(@fake), prefix: prefix, permissions: permissions
    )
  end

  # Registration with an explicit command: no MUD knowledge anywhere.
  def test_register_populates_the_registry_from_discovery
    ctx, registry = new_registry
    client = register(registry)

    assert_equal client.tools.size, ctx.tools.size
    assert ctx.tools.key?("look")
    assert_match(/You do: look/, registry.dispatch("look", {}))
  end

  # Prefixing is a policy applied agent-side. The server keeps its own names.
  def test_prefix_is_applied_locally_and_the_server_still_sees_bare_names
    ctx, registry = new_registry
    register(registry, prefix: "tbamud")

    assert ctx.tools.key?("tbamud__look")
    refute ctx.tools.key?("look")

    # If the prefix leaked onto the wire the daemon would reject this as an
    # unknown tool; getting the MUD's response back proves it didn't.
    assert_match(/You do: look/, registry.dispatch("tbamud__look", {}))
    assert_match(/You do: kill dragon/, registry.dispatch("tbamud__attack", "target" => "dragon"))
  end

  # Proves prefixing is opt-in policy, not baked into the mechanism.
  def test_nil_prefix_yields_bare_names
    ctx, registry = new_registry
    register(registry, prefix: nil)
    assert ctx.tools.key?("look")
    refute ctx.tools.key?("tbamud__look")
  end

  def test_schema_enum_is_surfaced_in_the_parameter_description
    ctx, registry = new_registry
    register(registry)
    assert_match(/one of:.*north/, ctx.tools["move"].parameters[:direction][:description])
  end

  # Silent clobbering would be maddening to debug, so a collision is a hard
  # error naming the fix. Two servers sharing a prefix is the realistic case.
  def test_colliding_tool_names_raise
    _ctx, registry = new_registry
    register(registry, prefix: "tbamud")

    second = nil
    err = assert_raises(ArgumentError) do
      second = Boukensha::Tools::Mcp.register(
        registry, command: mud_manager_command, args: mud_manager_args,
                  env: fake_mud_env(@fake), prefix: "tbamud"
      )
    end
    assert_match(/collision on 'tbamud__look'/, err.message)
    assert_match(/prefix/, err.message)
  ensure
    second&.close
  end

  # A collision against a tool boukensha registered itself (not another MCP
  # server) must be caught too — a filesystem server advertising `read_file`
  # is the obvious one.
  def test_collision_with_an_existing_non_mcp_tool_raises
    _ctx, registry = new_registry
    registry.tool("look", description: "pre-existing") { "local" }

    err = assert_raises(ArgumentError) { register(registry) }
    assert_match(/collision on 'look'/, err.message)
  end

  # --- permissions: end-to-end through the real discovery path ---

  def test_permissions_restrict_which_discovered_tools_actually_register
    ctx = Boukensha::Context.new(system: "test")
    perms = Boukensha::Permissions.new(["move"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)
    register(registry, permissions: perms)

    assert_includes ctx.tools.keys, "move"
    refute_includes ctx.tools.keys, "look"
    # The daemon still advertised everything; permissions is what filtered it.
    refute_equal @client.tools.size, ctx.tools.size
  end

  def test_permissions_narrow_the_advertised_enum_description
    ctx = Boukensha::Context.new(system: "test")
    perms = Boukensha::Permissions.new(["move(direction: north|south)"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)
    register(registry, permissions: perms)

    desc = ctx.tools["move"].parameters[:direction][:description]
    assert_match(/one of: north, south/, desc)
    refute_match(/east/, desc)
  end

  def test_permissions_dispatch_guard_rejects_a_pinned_out_of_range_value
    ctx = Boukensha::Context.new(system: "test")
    perms = Boukensha::Permissions.new(["move(direction: north)"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)
    register(registry, permissions: perms)

    assert_match(/You do: north/, registry.dispatch("move", "direction" => "north"))
    assert_raises(Boukensha::UnauthorizedToolError) { registry.dispatch("move", "direction" => "south") }
  end

  def test_permissions_validate_tool_fails_loudly_at_registration_for_a_bad_enum_value
    ctx = Boukensha::Context.new(system: "test")
    perms = Boukensha::Permissions.new(["move(direction: teleport)"])
    registry = Boukensha::Registry.new(ctx, permissions: perms)

    err = assert_raises(Boukensha::Permissions::InvalidRuleError) { register(registry, permissions: perms) }
    assert_match(/teleport is not a valid direction/, err.message)
  end

  def test_permissions_bare_rule_matches_a_prefixed_discovered_tool
    ctx = Boukensha::Context.new(system: "test")
    perms = Boukensha::Permissions.new(["look"]) # bare — no tbamud__ prefix needed
    registry = Boukensha::Registry.new(ctx, permissions: perms)
    register(registry, prefix: "tbamud", permissions: perms)

    assert_includes ctx.tools.keys, "tbamud__look"
    refute_includes ctx.tools.keys, "tbamud__move"
  end
end
