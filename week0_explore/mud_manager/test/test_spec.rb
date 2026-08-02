require_relative "helper"
require "mud_manager/mcp/spec"

class TestSpec < Minitest::Test
  def test_tool_count_is_twenty_six
    assert_equal 26, MudManager::Mcp::ToolSpec::TOOLS.size
  end

  def test_every_tool_has_a_name_and_description
    MudManager::Mcp::ToolSpec::TOOLS.each do |t|
      refute_empty t.name
      refute_empty t.description.to_s
    end
  end

  # Enums are pulled live from MudManager::Primitives, so they can never
  # drift from the domain gem's own command table.
  def test_dump_pulls_enums_live_from_primitives
    doc = MudManager::Mcp::Spec.document
    assert_equal MudManager::Primitives::DIRECTIONS, doc["tools"]["move"]["args"]["direction"]["values"]
    assert_equal MudManager::Primitives::ATTACK_STYLES, doc["tools"]["attack"]["args"]["style"]["values"]
  end

  def test_dump_stamps_the_gem_version
    assert_equal MudManager::VERSION, MudManager::Mcp::Spec.document["mud_manager_version"]
  end

  def test_to_mcp_tools_shape
    look = MudManager::Mcp::ToolSpec.to_mcp_tools.find { |t| t["name"] == "look" }
    assert_equal "object", look["inputSchema"]["type"]
    assert look["inputSchema"]["properties"].key?("target")
    assert_equal [], MudManager::Mcp::ToolSpec.to_mcp_tools.find { |t| t["name"] == "move" }["inputSchema"]["required"].then { |r| r - ["direction"] }
  end
end
