require_relative "helper"

class TestPermissions < Minitest::Test
  def test_permissive_by_default_allows_any_tool_and_any_value
    perms = Boukensha::Permissions.new(nil)
    assert perms.permissive?
    assert perms.allow_tool?("anything")
    assert perms.call_permitted?("anything", { "kind" => "whatever" })
    assert_nil perms.allowed_values("anything", "kind")
  end

  def test_bare_rule_allows_the_tool_with_no_arguments
    perms = Boukensha::Permissions.new(["move"])
    refute perms.permissive?
    assert perms.allow_tool?("move")
    refute perms.allow_tool?("attack")
  end

  def test_bare_rule_matches_any_mcp_prefix
    perms = Boukensha::Permissions.new(["check"])
    assert perms.allow_tool?("check")
    assert perms.allow_tool?("tbamud__check")
    refute perms.allow_tool?("other__check__extra")
  end

  def test_prefixed_rule_matches_only_that_exact_name
    perms = Boukensha::Permissions.new(["tbamud__check"])
    assert perms.allow_tool?("tbamud__check")
    refute perms.allow_tool?("check")
    refute perms.allow_tool?("otherserver__check")
  end

  def test_pinned_values_gate_dispatch
    perms = Boukensha::Permissions.new(["check(kind: score|inventory)"])
    assert perms.call_permitted?("check", { "kind" => "score" })
    assert perms.call_permitted?("check", { "kind" => "inventory" })
    refute perms.call_permitted?("check", { "kind" => "exits" })
  end

  def test_unmentioned_parameter_is_unconstrained
    perms = Boukensha::Permissions.new(["get_item(obj: sword)"])
    assert perms.call_permitted?("get_item", { "obj" => "sword", "container" => "anything" })
    refute perms.call_permitted?("get_item", { "obj" => "shield" })
  end

  def test_wildcard_pattern_allows_any_value
    perms = Boukensha::Permissions.new(["consider(target: *)"])
    assert perms.call_permitted?("consider", { "target" => "dragon" })
    assert_nil perms.allowed_values("consider", "target")
  end

  def test_call_permitted_is_false_for_a_tool_no_rule_names
    perms = Boukensha::Permissions.new(["move"])
    refute perms.call_permitted?("attack", { "target" => "dragon" })
  end

  def test_allowed_values_narrows_for_enum_narrowing_call_sites
    perms = Boukensha::Permissions.new(["check(kind: score|inventory)"])
    assert_equal %w[score inventory], perms.allowed_values("check", "kind")
  end

  def test_invalid_rule_syntax_raises
    assert_raises(Boukensha::Permissions::InvalidRuleError) do
      Boukensha::Permissions.new(["not a valid rule("])
    end
  end

  # --- validate_tool! (boot-time schema check) ---

  SCHEMA = { "properties" => { "kind" => { "type" => "string", "enum" => %w[score inventory exits] } } }.freeze

  def test_validate_tool_passes_when_pinned_values_are_in_the_enum
    perms = Boukensha::Permissions.new(["check(kind: score|inventory)"])
    perms.validate_tool!("check", SCHEMA) # no raise
  end

  def test_validate_tool_raises_for_a_value_outside_the_enum
    perms = Boukensha::Permissions.new(["check(kind: teleport)"])
    err = assert_raises(Boukensha::Permissions::InvalidRuleError) { perms.validate_tool!("check", SCHEMA) }
    assert_match(/teleport is not a valid kind/, err.message)
  end

  def test_validate_tool_raises_for_an_unknown_parameter
    perms = Boukensha::Permissions.new(["check(knd: score)"])
    err = assert_raises(Boukensha::Permissions::InvalidRuleError) { perms.validate_tool!("check", SCHEMA) }
    assert_match(/no parameter 'knd'/, err.message)
  end

  def test_validate_tool_raises_for_a_non_constrainable_parameter
    perms = Boukensha::Permissions.new(["move(direction: north)"])
    schema = { "properties" => { "direction" => { "type" => "string" } } } # no enum
    err = assert_raises(Boukensha::Permissions::InvalidRuleError) { perms.validate_tool!("move", schema) }
    assert_match(/not constrainable/, err.message)
  end

  def test_validate_tool_is_a_noop_for_tools_no_rule_names
    perms = Boukensha::Permissions.new(["move"])
    perms.validate_tool!("check", SCHEMA) # no raise — no rule mentions check
  end

  # --- validate_referenced! (boot-time "does this rule point at a real tool?") ---

  def test_validate_referenced_passes_when_every_rule_matches_a_registered_tool
    perms = Boukensha::Permissions.new(["move", "tbamud__check"])
    perms.validate_referenced!(%w[move tbamud__check tbamud__attack])
  end

  def test_validate_referenced_raises_for_a_rule_naming_nothing_real
    perms = Boukensha::Permissions.new(["flyaway"])
    err = assert_raises(Boukensha::Permissions::InvalidRuleError) { perms.validate_referenced!(%w[move attack]) }
    assert_match(/unknown tool 'flyaway'/, err.message)
  end

  def test_validate_referenced_is_a_noop_when_permissive
    Boukensha::Permissions.permissive.validate_referenced!([]) # no raise
  end
end
