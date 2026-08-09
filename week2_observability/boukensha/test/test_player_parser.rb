require_relative "helper"
require "boukensha/mud/player_parser"

# Fixtures are verbatim captures from the live CircleMUD this project
# targets (test/fixtures/player/*.txt, docs/plans/player_map_plan.md Part 1
# Step 1) — not hand-written, same rule test_room_parser.rb follows.
class TestPlayerParser < Minitest::Test
  P = Boukensha::Mud::PlayerParser
  FIXTURES = File.expand_path("fixtures/player", __dir__)

  def fixture(name)
    File.read(File.join(FIXTURES, "#{name}.txt"))
  end

  def test_parse_score_reads_every_field_from_the_real_capture
    fields = P.parse_score(fixture("score"))

    assert_equal 18, fields[:age]
    assert_equal 22, fields[:hp]
    assert_equal 22, fields[:max_hp]
    assert_equal 100, fields[:mana]
    assert_equal 100, fields[:max_mana]
    assert_equal 83, fields[:move]
    assert_equal 83, fields[:max_move]
    assert_equal "39/10", fields[:armor_class]
    assert_equal 12, fields[:alignment]
    assert_equal 58, fields[:exp]
    assert_equal 0, fields[:gold]
    assert_equal 0, fields[:quest_points]
    assert_equal 1942, fields[:exp_to_next_level]
    assert_equal 1, fields[:level]
    assert_equal "standing", fields[:position]
  end

  def test_parse_score_position_ignores_hunger_and_thirst_lines
    # The real capture also has "You are hungry." and "You are thirsty."
    # after "You are standing." — neither is a position, and must not win.
    fields = P.parse_score(fixture("score"))
    refute_equal "hungry", fields[:position]
    refute_equal "thirsty", fields[:position]
  end

  def test_parse_inventory_reads_nothing_as_empty
    assert_equal [], P.parse_inventory(fixture("inventory"))
  end

  def test_parse_inventory_reads_a_populated_list
    text = "You are carrying:\r\r\n  a torch\r\r\n  a piece of rope (2)\r\r\n\r\r\n22H 100M 83V (news) (motd) > "
    items = P.parse_inventory(text)

    assert_equal [
      { descr: "a torch", keyword: "torch", quantity: 1 },
      { descr: "a piece of rope", keyword: "rope", quantity: 2 }
    ], items
  end

  def test_parse_equipment_reads_every_slot_from_the_real_capture
    items = P.parse_equipment(fixture("equipment"))

    assert_equal 18, items.length
    assert_equal({ slot: "used as light", descr: "a candle", keyword: "candle" }, items.first)
    assert_equal({ slot: "held", descr: "a metal staff", keyword: "staff" }, items.last)
  end

  def test_parse_equipment_disambiguates_repeated_slots
    items = P.parse_equipment(fixture("equipment"))
    finger_slots = items.select { |i| i[:slot].start_with?("worn on finger") }.map { |i| i[:slot] }

    assert_equal ["worn on finger", "worn on finger (2)"], finger_slots
    # Two neck slots and two wrist slots get the same treatment.
    assert_includes items.map { |i| i[:slot] }, "worn around neck (2)"
    assert_includes items.map { |i| i[:slot] }, "worn around wrist (2)"
  end

  def test_parse_equipment_keyword_drops_articles_and_pair_of
    items = P.parse_equipment(fixture("equipment"))
    leggings = items.find { |i| i[:descr] == "a pair of bronze leggings" }

    assert_equal "leggings", leggings[:keyword]
  end
end
