require_relative "../helper"
require "tmpdir"
require "sqlite3"
require "mud_monitor/knowledge_store"

module MudMonitor
  class KnowledgeStoreTest < Minitest::Test
    def build_db(path)
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE rooms (id INTEGER PRIMARY KEY, weak_fingerprint TEXT, strong_fingerprint TEXT,
          name TEXT, description TEXT, first_seen_at TEXT, last_seen_at TEXT, visit_count INTEGER, surveyed_at TEXT);
        CREATE TABLE room_exits (room_id INTEGER, direction TEXT, target_name TEXT, target_room_id INTEGER,
          traversals INTEGER, last_seen_at TEXT);
        CREATE TABLE entities (id INTEGER PRIMARY KEY, kind TEXT, descr TEXT, keyword TEXT, threat TEXT,
          threat_level INTEGER, health TEXT, seen_count INTEGER, first_seen_at TEXT, last_seen_at TEXT);
        CREATE TABLE entity_sightings (entity_id INTEGER, room_id INTEGER, count INTEGER, sighting_count INTEGER,
          first_seen_at TEXT, last_seen_at TEXT);
        CREATE TABLE player_state (id INTEGER PRIMARY KEY, current_room_id INTEGER, hp INTEGER, updated_at TEXT);
        CREATE TABLE player_inventory (id INTEGER PRIMARY KEY, descr TEXT, keyword TEXT, quantity INTEGER,
          first_seen_at TEXT, last_seen_at TEXT);
        CREATE TABLE player_equipment (id INTEGER PRIMARY KEY, slot TEXT, descr TEXT, keyword TEXT,
          first_seen_at TEXT, last_seen_at TEXT);

        INSERT INTO rooms VALUES (1, 'fp1', NULL, 'Market Square', 'busy', '2026-01-01', '2026-01-02', 2, '2026-01-01');
        INSERT INTO room_exits VALUES (1, 'north', 'Temple Square', NULL, 0, '2026-01-01');
        INSERT INTO entities VALUES (1, 'mob', 'A cityguard stands here.', 'cityguard', 'Easy.', 1, 'excellent', 3, '2026-01-01', '2026-01-02');
        INSERT INTO player_state VALUES (1, 1, 20, '2026-01-02');
        INSERT INTO player_inventory VALUES (1, 'a torch', 'torch', 1, '2026-01-01', '2026-01-02');
        INSERT INTO player_equipment VALUES (1, 'wielded', 'a small sword', 'sword', '2026-01-01', '2026-01-02');
      SQL
      db.close
    end

    def test_disabled_when_file_missing
      store = KnowledgeStore.new(File.join(Dir.mktmpdir, "nope.sqlite3"))
      refute store.enabled?
      assert_equal({ rooms: 0, entities: 0, frontiers: 0 }, store.counts)
      assert_empty store.rooms
      assert_nil store.player_state
      assert_empty store.player_inventory
      assert_empty store.player_equipment
    end

    def test_reads_rooms_entities_exits_and_player_state
      Dir.mktmpdir do |dir|
        path = File.join(dir, "knowledge.sqlite3")
        build_db(path)
        store = KnowledgeStore.new(path)

        assert store.enabled?
        assert_equal({ rooms: 1, entities: 1, frontiers: 1 }, store.counts)

        room = store.rooms.first
        assert_equal "Market Square", room["name"]

        exits = store.room_exits(room["id"])
        assert_equal "north", exits.first["direction"]

        entity = store.entities.first
        assert_equal "cityguard", entity["keyword"]

        player = store.player_state
        assert_equal 20, player["hp"]

        inventory = store.player_inventory
        assert_equal "a torch", inventory.first["descr"]

        equipment = store.player_equipment
        assert_equal "a small sword", equipment.first["descr"]
      end
    end

    def test_all_exits_returns_the_whole_graph_in_one_query
      Dir.mktmpdir do |dir|
        path = File.join(dir, "knowledge.sqlite3")
        build_db(path)
        db = SQLite3::Database.new(path)
        db.execute("INSERT INTO rooms VALUES (2, 'fp2', NULL, 'Temple Square', 'quiet', '2026-01-01', '2026-01-02', 1, '2026-01-01')")
        db.execute("INSERT INTO room_exits VALUES (2, 'south', 'Market Square', 1, 1, '2026-01-01')")
        db.close

        store = KnowledgeStore.new(path)
        exits = store.all_exits
        assert_equal 2, exits.length
        assert_equal ["north", "south"], exits.map { |e| e["direction"] }.sort
      end
    end

    def test_player_inventory_and_equipment_are_empty_on_a_pre_v2_db_without_those_tables
      Dir.mktmpdir do |dir|
        path = File.join(dir, "knowledge.sqlite3")
        db = SQLite3::Database.new(path)
        db.execute_batch("CREATE TABLE player_state (id INTEGER PRIMARY KEY);")
        db.close

        store = KnowledgeStore.new(path)
        assert_empty store.player_inventory
        assert_empty store.player_equipment
      end
    end
  end
end
