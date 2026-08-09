require_relative "helper"
require "boukensha/mud/memory/store"
require "boukensha/mud/knowledge_tool"

# Phase H — the world_knowledge query API over Phase D's room graph.
#
# Builds a small real map in an in-memory SQLite database, so the BFS and
# the formatting are exercised against the actual schema rather than stubs.
#
#   Temple --north--> Market --east--> Alley
#      ^                 |
#      |                 +--south--> Docks   (Docks has no way back)
#      |
#   (Market --south--> Temple, so Temple<->Market is walkable both ways)
#
# Market also has a `west` exit that has never been walked — the frontier.
class TestKnowledgeTool < Minitest::Test
  Tool = Boukensha::Mud::KnowledgeTool

  def setup
    @store = Boukensha::Mud::Memory::Store.new(":memory:")

    @temple = @store.insert_room(name: "The Temple",   description: "Quiet and cold.", weak_fingerprint: "fp-temple")
    @market = @store.insert_room(name: "Market Square", description: "Busy.",          weak_fingerprint: "fp-market")
    @alley  = @store.insert_room(name: "A Dark Alley",  description: "Narrow.",        weak_fingerprint: "fp-alley")
    @docks  = @store.insert_room(name: "The Docks",     description: "Salt air.",      weak_fingerprint: "fp-docks")

    link(@temple, "north", @market)
    link(@market, "south", @temple)
    link(@market, "east",  @alley)
    link(@market, "south_west", @docks)

    # A frontier: seen, never walked.
    @store.upsert_room_exit(room_id: @market, direction: "west", target_name: "Too dark to tell.")

    @store.update_player_state(current_room_id: @temple)
  end

  def teardown
    @store&.close
  end

  def link(from, direction, to)
    @store.upsert_room_exit(room_id: from, direction: direction, target_name: nil)
    @store.link_exit_target(room_id: from, direction: direction, target_room_id: to)
  end

  # ---- Store#route_to (BFS) --------------------------------------------

  def test_route_to_self_is_empty
    assert_equal [], @store.route_to(from_id: @temple, to_id: @temple)
  end

  def test_finds_a_single_step_route
    steps = @store.route_to(from_id: @temple, to_id: @market)
    assert_equal ["north"], steps.map { |s| s[:direction] }
    assert_equal ["Market Square"], steps.map { |s| s[:name] }
  end

  def test_finds_a_multi_step_route
    steps = @store.route_to(from_id: @temple, to_id: @alley)
    assert_equal %w[north east], steps.map { |s| s[:direction] }
    assert_equal ["Market Square", "A Dark Alley"], steps.map { |s| s[:name] }
  end

  # Edges are directed: the Docks were walked into, never out of.
  def test_returns_nil_when_no_route_is_known
    assert_nil @store.route_to(from_id: @docks, to_id: @temple)
  end

  # The frontier is not a route. `west` is a known exit of Market Square, but
  # it has never been walked, so it must not appear in any path.
  def test_an_unwalked_exit_is_never_part_of_a_route
    steps = @store.route_to(from_id: @temple, to_id: @alley)
    refute_includes steps.map { |s| s[:direction] }, "west"
  end

  def test_bfs_returns_the_shortest_route
    # Add a long way round: Temple -> Docks is 1 step via a new direct edge,
    # so it must beat any longer path.
    link(@temple, "down", @docks)
    steps = @store.route_to(from_id: @temple, to_id: @docks)
    assert_equal 1, steps.size
    assert_equal "down", steps.first[:direction]
  end

  # A cycle must not hang the search. Market<->Alley now loops; the route
  # out of it still has to terminate and be correct.
  def test_cycles_terminate
    link(@alley, "west", @market)

    steps = @store.route_to(from_id: @alley, to_id: @docks)
    assert_equal %w[west south_west], steps.map { |s| s[:direction] }
  end

  # ...and a cycle with genuinely no exit toward the target must return nil
  # rather than looping forever.
  def test_a_cycle_with_no_route_out_still_returns
    a = @store.insert_room(name: "Loop A", description: "x", weak_fingerprint: "fp-a")
    b = @store.insert_room(name: "Loop B", description: "x", weak_fingerprint: "fp-b")
    link(a, "north", b)
    link(b, "south", a)

    assert_nil @store.route_to(from_id: a, to_id: @temple)
  end

  # ---- Store#find_rooms_by_name ----------------------------------------

  def test_finds_a_room_by_exact_name_case_insensitively
    assert_equal @market, @store.find_rooms_by_name("market square").first["id"]
  end

  def test_finds_a_room_by_substring
    assert_equal @market, @store.find_rooms_by_name("Market").first["id"]
  end

  def test_unknown_name_finds_nothing
    assert_empty @store.find_rooms_by_name("Atlantis")
  end

  def test_blank_name_finds_nothing
    assert_empty @store.find_rooms_by_name("   ")
  end

  # ---- Store#all_exits --------------------------------------------------

  def test_all_exits_returns_the_whole_graph_in_one_query
    # 4 linked edges + 1 frontier
    assert_equal 5, @store.all_exits.size
  end

  # ---- the tool: overview ----------------------------------------------

  def test_overview_reports_size_and_position
    out = Tool.call(store: @store)
    assert_includes out, "4 rooms"
    assert_includes out, "1 unexplored exits"
    assert_includes out, "currently in: The Temple"
  end

  def test_overview_is_the_default_for_an_unknown_kind
    assert_equal Tool.call(store: @store), Tool.call(store: @store, kind: "nonsense")
  end

  # ---- the tool: room ---------------------------------------------------

  def test_room_defaults_to_the_current_room
    out = Tool.call(store: @store, kind: "room")
    assert_includes out, "The Temple"
    assert_includes out, "Quiet and cold."
  end

  def test_room_by_name_lists_exits_and_marks_the_frontier
    out = Tool.call(store: @store, kind: "room", name: "Market Square")

    assert_includes out, "Market Square"
    assert_includes out, "east→A Dark Alley ✓"
    assert_includes out, "west→Too dark to tell. (unexplored)"
  end

  def test_room_reports_an_unknown_name
    assert_includes Tool.call(store: @store, kind: "room", name: "Atlantis"), "Atlantis"
  end

  # More than one match is a normal outcome — the model is quoting prose.
  def test_ambiguous_room_names_ask_for_clarification
    @store.insert_room(name: "Market Square Annex", description: "x", weak_fingerprint: "fp-annex")
    out = Tool.call(store: @store, kind: "room", name: "Market")

    assert_includes out, "2 rooms match"
    assert_includes out, "exact name"
  end

  def test_room_shows_entities_seen_there
    entity_id = @store.upsert_entity(kind: "mob", descr: "The pit fiend is sitting here.",
                                     threat: "You ARE mad!")
    @store.upsert_sighting(entity_id: entity_id, room_id: @alley)

    out = Tool.call(store: @store, kind: "room", name: "A Dark Alley")
    assert_includes out, "pit fiend"
    assert_includes out, "You ARE mad!"
  end

  # ---- the tool: route --------------------------------------------------

  def test_route_renders_the_path
    out = Tool.call(store: @store, kind: "route", to: "A Dark Alley")
    assert_includes out, "2 steps"
    assert_includes out, "north→Market Square"
    assert_includes out, "east→A Dark Alley"
  end

  def test_route_needs_a_destination
    assert_includes Tool.call(store: @store, kind: "route"), "needs a destination"
  end

  def test_route_to_the_current_room_says_so
    assert_includes Tool.call(store: @store, kind: "route", to: "The Temple"), "already in"
  end

  def test_route_reports_an_unreachable_room
    @store.update_player_state(current_room_id: @docks)
    out = Tool.call(store: @store, kind: "route", to: "The Temple")

    assert_includes out, "no known route"
    assert_includes out, "not been walked"
  end

  def test_route_reports_an_unvisited_destination
    assert_includes Tool.call(store: @store, kind: "route", to: "Atlantis"), "has been visited"
  end

  # ---- failure posture --------------------------------------------------

  # Knowledge failing must degrade the caller to "doesn't know", never crash
  # its turn — the same posture Mud::Hooks takes.
  def test_a_broken_store_degrades_instead_of_raising
    broken = Object.new
    def broken.counts = raise(RuntimeError, "database is locked")

    out = Tool.call(store: broken)
    assert_includes out, "world knowledge unavailable"
    assert_includes out, "database is locked"
  end

  def test_unknown_current_room_is_reported_not_raised
    @store.update_player_state(current_room_id: nil)
    assert_includes Tool.call(store: @store, kind: "room"), "unknown"
  end

  # ---- registration -----------------------------------------------------

  def test_registers_as_a_dispatchable_tool
    ctx      = Boukensha::Context.new(system: "t")
    registry = Boukensha::Registry.new(ctx)
    Tool.register(registry, store: @store)

    assert_includes registry.tool_names, "world_knowledge"
    assert_includes registry.dispatch("world_knowledge", { "kind" => "room", "name" => "The Temple" }),
                    "Quiet and cold."
  end

  # The tool is read-only in the strong sense: it is on the Judge's
  # allowlist, and asking about the world cannot change it.
  def test_the_judge_is_allowed_to_call_it
    assert Boukensha::Tasks::Judge.permissions.allow_tool?("world_knowledge")
  end

  def test_dispatch_with_no_arguments_gives_the_overview
    ctx      = Boukensha::Context.new(system: "t")
    registry = Boukensha::Registry.new(ctx)
    Tool.register(registry, store: @store)

    assert_includes registry.dispatch("world_knowledge", {}), "known world:"
  end
end
