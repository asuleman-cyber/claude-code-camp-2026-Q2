module MudMonitor
  # Read-only reader of the agent's knowledge.sqlite3 (Phase D — see
  # boukensha/lib/boukensha/mud/memory/store.rb, the only writer). Opens a
  # fresh read-only connection per call rather than holding one open — at
  # this volume (a dev tool, not production traffic) that's free, and it
  # sidesteps the same class of Windows file-locking issue Phase B's
  # JsonlAppender hit with a long-held handle.
  class KnowledgeStore
    def initialize(path)
      @path = path
    end

    def enabled?
      @path && File.exist?(@path)
    end

    def counts
      return { rooms: 0, entities: 0, frontiers: 0 } unless enabled?

      with_db do |d|
        {
          rooms: d.get_first_value("SELECT COUNT(*) FROM rooms"),
          entities: d.get_first_value("SELECT COUNT(*) FROM entities"),
          frontiers: d.get_first_value("SELECT COUNT(*) FROM room_exits WHERE target_room_id IS NULL")
        }
      end
    end

    def rooms
      return [] unless enabled?

      with_db { |d| d.execute("SELECT * FROM rooms ORDER BY last_seen_at DESC") }
    end

    def room_exits(room_id)
      return [] unless enabled?

      with_db { |d| d.execute("SELECT * FROM room_exits WHERE room_id = ? ORDER BY direction", [room_id]) }
    end

    # Every room_exits row across the whole known world, in one query — the
    # map (player_map_plan.md Part 2 Step 8) needs the whole graph at once,
    # unlike #room_exits' per-room reads.
    def all_exits
      return [] unless enabled?

      with_db { |d| d.execute("SELECT * FROM room_exits") }
    end

    def entities
      return [] unless enabled?

      with_db { |d| d.execute("SELECT * FROM entities ORDER BY last_seen_at DESC") }
    end

    def entity_sightings(entity_id)
      return [] unless enabled?

      with_db do |d|
        d.execute(
          "SELECT rooms.name AS room_name, entity_sightings.* FROM entity_sightings " \
          "JOIN rooms ON rooms.id = entity_sightings.room_id WHERE entity_sightings.entity_id = ?",
          [entity_id]
        )
      end
    end

    def player_state
      return nil unless enabled?

      with_db { |d| d.execute("SELECT * FROM player_state WHERE id = 1").first }
    end

    # player_map_plan.md Part 1 Step 6 — mirrors #rooms/#entities above.
    # Empty (not an error) on a knowledge.sqlite3 from before Schema v2;
    # SQLite reports a missing table the same way as a missing file here.
    def player_inventory
      return [] unless enabled?

      with_db { |d| d.execute("SELECT * FROM player_inventory ORDER BY descr") }
    rescue SQLite3::SQLException
      []
    end

    def player_equipment
      return [] unless enabled?

      with_db { |d| d.execute("SELECT * FROM player_equipment ORDER BY slot") }
    rescue SQLite3::SQLException
      []
    end

    private

    def with_db
      require "sqlite3"
      db = SQLite3::Database.new(@path, readonly: true)
      db.results_as_hash = true
      yield db
    ensure
      db&.close
    end
  end
end
