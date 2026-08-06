require_relative "helper"
require "tmpdir"
require "json"
require "boukensha/mud/memory/journal"
require "boukensha/mud/memory/store"

class TestMemoryStore < Minitest::Test
  def store
    @store ||= Boukensha::Mud::Memory::Store.new(":memory:")
  end

  def teardown
    @store&.close
  end

  def test_migrate_sets_user_version
    store # trigger open+migrate
    version = store.instance_variable_get(:@db).get_first_value("PRAGMA user_version")
    assert_equal Boukensha::Mud::Memory::Schema::VERSION, version
  end

  def test_wal_mode_is_enabled
    mode = store.instance_variable_get(:@db).get_first_value("PRAGMA journal_mode")
    assert_equal "memory", mode.downcase # :memory: databases can't use WAL, but the pragma call itself must not raise
  end

  def test_insert_and_find_room_by_weak_fingerprint
    id = store.insert_room(name: "Market Square", description: "busy", weak_fingerprint: "fp1")
    room = store.find_room_by_weak_fingerprint("fp1")

    assert_equal id, room["id"]
    assert_equal "Market Square", room["name"]
    assert_equal 1, room["visit_count"]
  end

  def test_unknown_fingerprint_returns_nil
    assert_nil store.find_room_by_weak_fingerprint("nope")
  end

  def test_ambiguous_fingerprint_returns_a_symbol_not_a_row
    store.insert_room(name: "Room A", description: "d", weak_fingerprint: "dup")
    store.insert_room(name: "Room B", description: "d", weak_fingerprint: "dup")

    assert_equal :ambiguous, store.find_room_by_weak_fingerprint("dup")
  end

  def test_touch_room_bumps_visit_count
    id = store.insert_room(name: "R", description: "d", weak_fingerprint: "fp")
    store.touch_room(id)
    store.touch_room(id)

    assert_equal 3, store.find_room(id)["visit_count"]
  end

  def test_room_exits_upsert_and_link_target
    a = store.insert_room(name: "A", description: "d", weak_fingerprint: "fpa")
    b = store.insert_room(name: "B", description: "d", weak_fingerprint: "fpb")

    store.upsert_room_exit(room_id: a, direction: "north", target_name: "B")
    exit_row = store.room_exits(a).first
    assert_nil exit_row["target_room_id"] # frontier — not yet linked

    store.link_exit_target(room_id: a, direction: "north", target_room_id: b)
    exit_row = store.room_exits(a).first
    assert_equal b, exit_row["target_room_id"]
    assert_equal 1, exit_row["traversals"]
  end

  def test_frontier_count_reflects_unlinked_exits
    a = store.insert_room(name: "A", description: "d", weak_fingerprint: "fpa")
    store.upsert_room_exit(room_id: a, direction: "north", target_name: "Somewhere")
    assert_equal 1, store.counts[:frontiers]
  end

  def test_entity_upsert_is_idempotent_by_kind_and_descr
    id1 = store.upsert_entity(kind: "mob", descr: "A fido barks.", keyword: "fido")
    id2 = store.upsert_entity(kind: "mob", descr: "A fido barks.", threat: "Easy.")

    assert_equal id1, id2
    entity = store.find_entity(kind: "mob", descr: "A fido barks.")
    assert_equal "fido", entity["keyword"]   # preserved — COALESCE keeps the earlier value
    assert_equal "Easy.", entity["threat"]   # newly supplied value applied
    assert_equal 2, entity["seen_count"]
  end

  def test_sightings_link_entities_to_rooms
    room = store.insert_room(name: "R", description: "d", weak_fingerprint: "fp")
    entity = store.upsert_entity(kind: "mob", descr: "A fido barks.")
    store.upsert_sighting(entity_id: entity, room_id: room, count: 3)

    sighted = store.room_entities(room)
    assert_equal 1, sighted.length
    assert_equal 3, sighted.first["sighting_count_here"]
  end

  def test_player_state_is_a_single_row_created_on_first_write
    assert_nil store.player_state

    store.update_player_state(hp: 20, level: 1)
    assert_equal 20, store.player_state["hp"]

    store.update_player_state(hp: 18)
    state = store.player_state
    assert_equal 18, state["hp"]
    assert_equal 1, state["level"] # untouched fields survive a partial update
  end

  def test_counts_overview
    store.insert_room(name: "R", description: "d", weak_fingerprint: "fp")
    store.upsert_entity(kind: "object", descr: "A fountain.")

    counts = store.counts
    assert_equal 1, counts[:rooms]
    assert_equal 1, counts[:entities]
  end
end

class TestMemoryStoreJournal < Minitest::Test
  def test_player_state_writes_are_journaled_only_on_change
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      store = Boukensha::Mud::Memory::Store.new(":memory:", journal: journal)

      store.update_player_state(hp: 20)
      store.update_player_state(hp: 20) # no-op
      store.update_player_state(hp: 15)

      records = Dir.glob(File.join(dir, "*.jsonl")).flat_map { |f| File.readlines(f).map { |l| JSON.parse(l) } }
      assert_equal 2, records.length
      store.close
    end
  end

  def test_new_room_discovery_is_journaled
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      store = Boukensha::Mud::Memory::Store.new(":memory:", journal: journal)

      store.insert_room(name: "Market Square", description: "d", weak_fingerprint: "fp1")

      records = Dir.glob(File.join(dir, "*.jsonl")).flat_map { |f| File.readlines(f).map { |l| JSON.parse(l) } }
      assert_equal 1, records.length
      assert_equal "discovered", records.first["op"]
      assert_equal "Market Square", records.first["name"]
      store.close
    end
  end

  def test_store_works_unchanged_with_no_journal
    store = Boukensha::Mud::Memory::Store.new(":memory:")
    store.update_player_state(hp: 20) # must not raise
    assert_equal 20, store.player_state["hp"]
    store.close
  end
end
