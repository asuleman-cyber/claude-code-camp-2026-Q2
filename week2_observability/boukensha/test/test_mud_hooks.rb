require_relative "helper"
require "boukensha/context"
require "boukensha/mud/memory/store"
require "boukensha/mud/hooks"

class TestMudHooks < Minitest::Test
  ROOM_A_INSPECT = "== look ==\n\e[0;33mMarket Square\e[0m\r\n   A busy square.\r\n\e[0;36m[ Exits: n e ]\e[0m\r\n\e[0;33mA cityguard stands here.\r\n\e[0m\r\n20H 100M 42V (news) (motd) > \n\n== exits ==\nObvious exits:\r\nnorth - Temple Square\r\neast  - Main Street\r\n\r\n20H 100M 42V (news) (motd) > ".freeze
  ROOM_B_INSPECT = "== look ==\n\e[0;33mTemple Square\e[0m\r\n   A quiet square.\r\n\e[0;36m[ Exits: s ]\e[0m\r\n\e[0m\r\n20H 100M 41V (news) (motd) > \n\n== exits ==\nObvious exits:\r\nsouth - Market Square\r\n\r\n20H 100M 41V (news) (motd) > ".freeze
  ROOM_B_MOVE = "\e[0;33mTemple Square\e[0m\r\n   A quiet square.\r\n\e[0;36m[ Exits: s ]\e[0m\r\n\e[0m\r\n20H 100M 41V (news) (motd) > ".freeze
  ROOM_A_MOVE = "\e[0;33mMarket Square\e[0m\r\n   A busy square.\r\n\e[0;36m[ Exits: n e ]\e[0m\r\n\e[0;33mA cityguard stands here.\r\n\e[0m\r\n20H 100M 40V (news) (motd) > ".freeze
  FAILURE_TEXT = "Alas, you cannot go that way.\r\n\r\n20H 100M 42V (news) (motd) > ".freeze

  SCORE_TEXT = "You are 20 years old.\r\nYou have 20(20) hit, 100(100) mana and 42(42) movement points.\r\n" \
               "Your armor class is 39/10, and your alignment is 12.\r\nYou have 58 exp, 5 gold coins, and 0 questpoints.\r\n" \
               "You need 1942 exp to reach your next level.\r\nYou have earned 0 quest points.\r\n" \
               "This ranks you as Dummy the Swordpupil (level 1).\r\nYou are standing.\r\n\r\n20H 100M 42V (news) (motd) > ".freeze
  INVENTORY_TEXT = "You are carrying:\r\n  a torch\r\n\r\n20H 100M 42V (news) (motd) > ".freeze
  EQUIPMENT_TEXT = "You are using:\r\n<wielded>            a small sword\r\n\r\n20H 100M 42V (news) (motd) > ".freeze

  def setup
    @store = Boukensha::Mud::Memory::Store.new(":memory:")
    @calls = []
    @current_room = :a
    @responses = {
      ["poll", {}] => "",
      ["consider", { "target" => "cityguard" }] => "Easy.\r\n\r\n20H 100M 42V (news) (motd) > ",
      ["examine", { "target" => "cityguard" }] => "A guard.\r\nThe cityguard is in excellent condition.\r\n\r\n20H 100M 42V (news) (motd) > ",
      ["send_raw", { "raw" => "score" }] => SCORE_TEXT,
      ["send_raw", { "raw" => "inventory" }] => INVENTORY_TEXT,
      ["send_raw", { "raw" => "equipment" }] => EQUIPMENT_TEXT
    }
    @call_tool = lambda do |name, args|
      @calls << [name, args]
      if name == "inspect"
        @current_room == :a ? ROOM_A_INSPECT : ROOM_B_INSPECT
      else
        @responses.fetch([name, args]) { @responses.fetch(name) { raise "unexpected #{name}(#{args.inspect})" } }
      end
    end
    @hooks = Boukensha::Mud::Hooks.new(call_tool: @call_tool, store: @store)
    @ctx   = Boukensha::Context.new(system: "test")
  end

  def teardown
    @store.close
  end

  def test_cold_start_surveys_and_sets_a_state_block
    @hooks.before_model(context: @ctx)

    assert_match(/\[here\] Market Square/, @ctx.state_block)
    assert_match(/cityguard/, @ctx.state_block)
    # Three send_raws on the first survey: score, then the once-per-process
    # cold-start inventory/equipment sync.
    assert_equal %w[poll inspect consider examine send_raw send_raw send_raw], @calls.map(&:first)
    assert_equal %w[score inventory equipment],
                 @calls.select { |c| c.first == "send_raw" }.map { |c| c.last["raw"] }
    assert_equal 1, @store.counts[:rooms]
  end

  # The gap this closes: a character logs in already wearing a full kit, and
  # an agent that never calls an item tool used to leave both item tables
  # empty for the whole run.
  def test_cold_start_survey_syncs_inventory_and_equipment_without_any_item_tool_call
    @hooks.before_model(context: @ctx)

    assert_equal ["a torch"], @store.player_inventory.map { |i| i["descr"] }
    assert_equal ["a small sword"], @store.player_equipment.map { |i| i["descr"] }
  end

  def test_a_later_new_room_survey_does_not_re_sync_items
    @hooks.before_model(context: @ctx) # cold start: syncs items once
    @calls.clear

    @current_room = :b
    @hooks.after_tool(name: "tbamud__move", args: { "direction" => "north" },
                      result: ROOM_B_MOVE, context: @ctx)
    @hooks.before_model(context: @ctx) # a NEW room, so it surveys again

    raws = @calls.select { |c| c.first == "send_raw" }.map { |c| c.last["raw"] }
    assert_equal ["score"], raws, "score refreshes per new room; items only once per process"
  end

  def test_new_room_survey_also_refreshes_score
    @hooks.before_model(context: @ctx)

    state = @store.player_state
    assert_equal 20, state["age"]
    assert_equal "39/10", state["armor_class"]
    assert_equal 12, state["alignment"]
    assert_equal 1942, state["exp_to_next_level"]
    assert_equal 0, state["quest_points"]
  end

  def test_a_known_room_revisit_does_not_refresh_score
    @hooks.before_model(context: @ctx) # cold start, surveys once
    @calls.clear

    @hooks.before_model(context: @ctx) # same room, no move: zero calls
    refute_includes @calls.map(&:first), "send_raw"
  end

  def test_item_tool_refreshes_inventory_and_equipment
    @hooks.after_tool(name: "tbamud__get_item", args: { "obj" => "torch" }, result: "You get a torch.", context: @ctx)

    assert_equal ["a torch"], @store.player_inventory.map { |i| i["descr"] }
    assert_equal ["a small sword"], @store.player_equipment.map { |i| i["descr"] }
    assert_equal [["send_raw", { "raw" => "inventory" }], ["send_raw", { "raw" => "equipment" }]], @calls
  end

  def test_non_item_tool_does_not_refresh_inventory_or_equipment
    @hooks.after_tool(name: "tbamud__shop", args: { "op" => "list" }, result: "ok", context: @ctx)

    assert_empty @store.player_inventory
    assert_empty @calls.select { |c| c.first == "send_raw" }
  end

  def test_a_new_room_reached_by_move_is_surveyed_and_the_edge_is_linked
    @hooks.before_model(context: @ctx) # establish Market Square first

    @calls.clear
    @current_room = :b
    stub = @hooks.after_tool(name: "tbamud__move", args: { "direction" => "north" }, result: ROOM_B_MOVE, context: @ctx)
    assert_equal "moved north → Temple Square", stub

    @hooks.before_model(context: @ctx)
    assert_match(/\[here\] Temple Square/, @ctx.state_block)
    assert_equal 2, @store.counts[:rooms]

    market = @store.all_rooms.find { |r| r["name"] == "Market Square" }
    north_exit = @store.room_exits(market["id"]).find { |e| e["direction"] == "north" }
    refute_nil north_exit["target_room_id"] # the frontier is now a known edge
    assert_equal 1, north_exit["traversals"]
  end

  def test_returning_to_a_known_room_costs_zero_mud_calls
    @hooks.before_model(context: @ctx) # Market Square
    @current_room = :b
    @hooks.after_tool(name: "tbamud__move", args: { "direction" => "north" }, result: ROOM_B_MOVE, context: @ctx)
    @hooks.before_model(context: @ctx) # Temple Square (new room, surveyed)

    @calls.clear
    @current_room = :a
    @hooks.after_tool(name: "tbamud__move", args: { "direction" => "south" }, result: ROOM_A_MOVE, context: @ctx)
    @hooks.before_model(context: @ctx)

    assert_empty @calls
    assert_match(/\[here\] Market Square  \(visit 2\)/, @ctx.state_block)
    assert_match(/north→Temple Square ✓/, @ctx.state_block) # now a known edge, not a frontier
  end

  def test_no_move_since_last_resolution_also_costs_zero_calls
    @hooks.before_model(context: @ctx)

    @calls.clear
    @hooks.before_model(context: @ctx) # nothing moved; same room reused

    assert_empty @calls
    assert_match(/\[here\] Market Square/, @ctx.state_block)
  end

  def test_a_failed_move_is_never_substituted_or_fingerprinted
    stub = @hooks.after_tool(name: "tbamud__move", args: { "direction" => "east" }, result: FAILURE_TEXT, context: @ctx)

    assert_nil stub # nil -> Agent keeps the original text, verbatim
    assert_equal 0, @store.counts[:rooms] # nothing was recorded from a failure
  end

  def test_non_movement_tools_are_never_fingerprinted
    stub = @hooks.after_tool(name: "tbamud__shop", args: { "op" => "list" }, result: ROOM_A_MOVE, context: @ctx)
    assert_nil stub
  end

  def test_after_tool_scrapes_vitals_off_any_result
    @hooks.after_tool(name: "tbamud__shop", args: {}, result: "You buy a sword.\r\n\r\n15H 90M 30V (news) (motd) > ", context: @ctx)

    state = @store.player_state
    assert_equal 15, state["hp"]
    assert_equal 90, state["mana"]
    assert_equal 30, state["move"]
  end

  def test_before_tools_polls_and_scrapes_vitals
    @responses[["poll", {}]] = "The Mayor has arrived.\r\n18H 100M 42V (news) (motd) > "
    @hooks.before_tools(calls: [], context: @ctx)

    assert_equal 18, @store.player_state["hp"]
  end

  def test_a_broken_call_tool_degrades_silently_instead_of_raising
    broken = ->(_name, _args) { raise "MUD connection lost" }
    hooks = Boukensha::Mud::Hooks.new(call_tool: broken, store: @store)

    hooks.before_model(context: @ctx) # must not raise
    assert_nil @ctx.state_block # nothing was ever established; honest, not a crash
  end
end
