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

        INSERT INTO rooms VALUES (1, 'fp1', NULL, 'Market Square', 'busy', '2026-01-01', '2026-01-02', 2, '2026-01-01');
        INSERT INTO room_exits VALUES (1, 'north', 'Temple Square', NULL, 0, '2026-01-01');
        INSERT INTO entities VALUES (1, 'mob', 'A cityguard stands here.', 'cityguard', 'Easy.', 1, 'excellent', 3, '2026-01-01', '2026-01-02');
        INSERT INTO player_state VALUES (1, 1, 20, '2026-01-02');
      SQL
      db.close
    end

    def test_disabled_when_file_missing
      store = KnowledgeStore.new(File.join(Dir.mktmpdir, "nope.sqlite3"))
      refute store.enabled?
      assert_equal({ rooms: 0, entities: 0, frontiers: 0 }, store.counts)
      assert_empty store.rooms
      assert_nil store.player_state
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
      end
    end
  end
end
