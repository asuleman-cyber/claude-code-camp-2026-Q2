require "time"
require_relative "schema"

module Boukensha
  module Mud
    module Memory
      # The ONLY writer of knowledge.sqlite3. mud_monitor reads the same
      # file read-only, exactly as it already does for sessions/, manager/,
      # and telnet/ (Phase B) — Store never coordinates with it, the file is
      # the interface.
      #
      # `sqlite3` is required here, not from boukensha.rb, so a checkout
      # that never wires Mud::Hooks still boots without the gem installed —
      # same posture the source plan recommends for its ONNX dependency.
      #
      # Room identity is simplified from the source plan (basic_memory.md
      # §4): weak-fingerprint lookup only — exactly one match is "known,"
      # zero is "new," and (rare, in a MUD this size) more than one is
      # treated as "new" rather than attempting the plan's arrival-edge/
      # strong-fingerprint disambiguation. See this gem's report doc for
      # why that's an acceptable simplification here and what it would take
      # to add the fuller resolver.
      class Store
        def self.open(path, journal: nil)
          require "sqlite3"
          new(path, journal: journal)
        end

        # journal: optional Memory::Journal (Phase E — change_capture.md).
        # When given, player_state writes and new-room discovery are
        # recorded as a time series alongside the snapshot — see Journal's
        # own doc for the scope note on what is/isn't journaled yet.
        def initialize(path, journal: nil)
          require "sqlite3"
          @db = SQLite3::Database.new(path.to_s)
          @db.results_as_hash = true
          @journal = journal
          apply_pragmas!
          migrate!
        end

        def close
          @db.close
        end

        # ---------- rooms -------------------------------------------------

        # nil (no match), a room Hash (exactly one match), or :ambiguous
        # (more than one — caller treats this the same as "new," per the
        # simplification noted above).
        def find_room_by_weak_fingerprint(fingerprint)
          rows = @db.execute("SELECT * FROM rooms WHERE weak_fingerprint = ?", [fingerprint])
          case rows.length
          when 0 then nil
          when 1 then rows.first
          else :ambiguous
          end
        end

        def find_room(id)
          @db.execute("SELECT * FROM rooms WHERE id = ?", [id]).first
        end

        def insert_room(name:, description:, weak_fingerprint:, strong_fingerprint: nil, surveyed: false)
          now = now_iso
          @db.execute(
            "INSERT INTO rooms (weak_fingerprint, strong_fingerprint, name, description, " \
            "first_seen_at, last_seen_at, visit_count, surveyed_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?)",
            [weak_fingerprint, strong_fingerprint, name, description, now, now, surveyed ? now : nil]
          )
          id = @db.last_insert_row_id
          @journal&.event(stream: "room", op: "discovered", room_id: id, name: name)
          id
        end

        def touch_room(id)
          @db.execute("UPDATE rooms SET visit_count = visit_count + 1, last_seen_at = ? WHERE id = ?", [now_iso, id])
        end

        def mark_surveyed(id, strong_fingerprint:)
          @db.execute("UPDATE rooms SET strong_fingerprint = ?, surveyed_at = ? WHERE id = ?",
                      [strong_fingerprint, now_iso, id])
        end

        # ---------- room_exits (the map) -----------------------------------

        def upsert_room_exit(room_id:, direction:, target_name: nil)
          @db.execute(
            "INSERT INTO room_exits (room_id, direction, target_name, last_seen_at) VALUES (?, ?, ?, ?) " \
            "ON CONFLICT(room_id, direction) DO UPDATE SET target_name = excluded.target_name, last_seen_at = excluded.last_seen_at",
            [room_id, direction, target_name, now_iso]
          )
        end

        # Called once we've actually stood in the destination — this is what
        # turns a frontier (target_room_id NULL) into a known edge.
        def link_exit_target(room_id:, direction:, target_room_id:)
          @db.execute(
            "UPDATE room_exits SET target_room_id = ?, traversals = traversals + 1, last_seen_at = ? " \
            "WHERE room_id = ? AND direction = ?",
            [target_room_id, now_iso, room_id, direction]
          )
        end

        def room_exits(room_id)
          @db.execute("SELECT * FROM room_exits WHERE room_id = ?", [room_id])
        end

        # ---------- entities (world-level) ---------------------------------

        def find_entity(kind:, descr:)
          @db.execute("SELECT * FROM entities WHERE kind = ? AND descr = ?", [kind, descr]).first
        end

        def upsert_entity(kind:, descr:, keyword: nil, threat: nil, threat_level: nil, health: nil)
          now = now_iso
          @db.execute(
            "INSERT INTO entities (kind, descr, keyword, threat, threat_level, health, seen_count, first_seen_at, last_seen_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?) " \
            "ON CONFLICT(kind, descr) DO UPDATE SET " \
            "keyword = COALESCE(excluded.keyword, entities.keyword), " \
            "threat = COALESCE(excluded.threat, entities.threat), " \
            "threat_level = COALESCE(excluded.threat_level, entities.threat_level), " \
            "health = COALESCE(excluded.health, entities.health), " \
            "seen_count = entities.seen_count + 1, last_seen_at = excluded.last_seen_at",
            [kind, descr, keyword, threat, threat_level, health, now, now]
          )
          find_entity(kind: kind, descr: descr)["id"]
        end

        def upsert_sighting(entity_id:, room_id:, count: 1)
          now = now_iso
          @db.execute(
            "INSERT INTO entity_sightings (entity_id, room_id, count, sighting_count, first_seen_at, last_seen_at) " \
            "VALUES (?, ?, ?, 1, ?, ?) " \
            "ON CONFLICT(entity_id, room_id) DO UPDATE SET " \
            "count = excluded.count, sighting_count = entity_sightings.sighting_count + 1, last_seen_at = excluded.last_seen_at",
            [entity_id, room_id, count, now, now]
          )
        end

        def room_entities(room_id)
          @db.execute(
            "SELECT entities.*, entity_sightings.count AS sighting_count_here " \
            "FROM entity_sightings JOIN entities ON entities.id = entity_sightings.entity_id " \
            "WHERE entity_sightings.room_id = ?",
            [room_id]
          )
        end

        # ---------- player_state (exactly one row) --------------------------

        def player_state
          @db.execute("SELECT * FROM player_state WHERE id = 1").first
        end

        def update_player_state(fields)
          return if fields.empty?

          fields.each { |k, v| @journal&.upsert(stream: "player", key: k.to_s, value: v) }

          columns = fields.keys
          set_clause = columns.map { |c| "#{c} = ?" }.join(", ")
          insert_columns = (["id"] + columns).join(", ")
          insert_placeholders = (["1"] + columns.map { "?" }).join(", ")

          @db.execute(
            "INSERT INTO player_state (#{insert_columns}, updated_at) VALUES (#{insert_placeholders}, ?) " \
            "ON CONFLICT(id) DO UPDATE SET #{set_clause}, updated_at = excluded.updated_at",
            fields.values + [now_iso] + fields.values
          )
        end

        # ---------- player score/inventory/equipment (player_map_plan.md) --

        # Same upsert-on-player_state shape as update_player_state (that
        # method is already fully generic over column names — a `score`
        # reading just happens to populate more of them). A distinct method
        # exists so a score-refresh call site in Mud::Hooks reads as what it
        # is, per plan Part 1 Step 4.
        def update_player_score(fields)
          update_player_state(fields)
        end

        def player_inventory
          @db.execute("SELECT * FROM player_inventory ORDER BY descr")
        end

        def player_equipment
          @db.execute("SELECT * FROM player_equipment ORDER BY slot")
        end

        # Reconciles the whole carried-items list against what's stored:
        # upserts every descr still present, deletes every descr that
        # dropped out. `items`: [{ descr:, keyword:, quantity: }, ...]
        # (Mud::PlayerParser#parse_inventory's shape). Journals a discrete
        # `add`/`remove` event per descr that actually appeared/disappeared
        # — a quantity-only change on an already-known item is not an event,
        # just an upsert (per plan Step 4).
        def replace_inventory!(items)
          now = now_iso
          incoming = items.map { |i| i[:descr] }

          @db.execute("SELECT descr FROM player_inventory").each do |row|
            descr = row["descr"]
            next if incoming.include?(descr)

            @db.execute("DELETE FROM player_inventory WHERE descr = ?", [descr])
            @journal&.event(stream: "inventory", op: "remove", descr: descr)
          end

          items.each do |item|
            existing = @db.execute("SELECT id FROM player_inventory WHERE descr = ?", [item[:descr]]).first
            if existing
              @db.execute(
                "UPDATE player_inventory SET keyword = ?, quantity = ?, last_seen_at = ? WHERE id = ?",
                [item[:keyword], item[:quantity] || 1, now, existing["id"]]
              )
            else
              @db.execute(
                "INSERT INTO player_inventory (descr, keyword, quantity, first_seen_at, last_seen_at) " \
                "VALUES (?, ?, ?, ?, ?)",
                [item[:descr], item[:keyword], item[:quantity] || 1, now, now]
              )
              @journal&.event(stream: "inventory", op: "add", descr: item[:descr])
            end
          end
        end

        # Same reconciliation as replace_inventory!, keyed by `slot`
        # (UNIQUE — one item per slot, see Schema v2) rather than `descr`.
        # A slot whose occupant changed (a swap, not a bare add/remove)
        # journals both an `unequip` of the old item and an `equip` of the
        # new one. `items`: [{ slot:, descr:, keyword: }, ...]
        # (Mud::PlayerParser#parse_equipment's shape).
        def replace_equipment!(items)
          now = now_iso
          incoming = items.map { |i| i[:slot] }

          @db.execute("SELECT slot FROM player_equipment").each do |row|
            slot = row["slot"]
            next if incoming.include?(slot)

            @db.execute("DELETE FROM player_equipment WHERE slot = ?", [slot])
            @journal&.event(stream: "equipment", op: "unequip", slot: slot)
          end

          items.each do |item|
            existing = @db.execute("SELECT id, descr FROM player_equipment WHERE slot = ?", [item[:slot]]).first
            if existing
              if existing["descr"] != item[:descr]
                @journal&.event(stream: "equipment", op: "unequip", slot: item[:slot], descr: existing["descr"])
                @journal&.event(stream: "equipment", op: "equip", slot: item[:slot], descr: item[:descr])
              end
              @db.execute(
                "UPDATE player_equipment SET descr = ?, keyword = ?, last_seen_at = ? WHERE id = ?",
                [item[:descr], item[:keyword], now, existing["id"]]
              )
            else
              @db.execute(
                "INSERT INTO player_equipment (slot, descr, keyword, first_seen_at, last_seen_at) " \
                "VALUES (?, ?, ?, ?, ?)",
                [item[:slot], item[:descr], item[:keyword], now, now]
              )
              @journal&.event(stream: "equipment", op: "equip", slot: item[:slot], descr: item[:descr])
            end
          end
        end

        # ---------- overview (Mud Monitor's knowledge tab) ------------------

        def counts
          {
            rooms: @db.get_first_value("SELECT COUNT(*) FROM rooms"),
            entities: @db.get_first_value("SELECT COUNT(*) FROM entities"),
            frontiers: @db.get_first_value("SELECT COUNT(*) FROM room_exits WHERE target_room_id IS NULL")
          }
        end

        def all_rooms
          @db.execute("SELECT * FROM rooms ORDER BY last_seen_at DESC")
        end

        def all_entities
          @db.execute("SELECT * FROM entities ORDER BY last_seen_at DESC")
        end

        # ---------- queries (Phase H — knowledge as a query API) ------------
        # Read-only. Until Phase H the only way knowledge reached a model was
        # Mud::Hooks injecting the *current* room's state block; nothing could
        # ask about a room it wasn't standing in, or whether two rooms
        # connect. These are what the `world_knowledge` native tool is built
        # on (Mud::KnowledgeTool).

        # The whole map in one query, rather than N+1 per-room `room_exits`
        # reads. mud_monitor's KnowledgeStore proved this shape out for the
        # /knowledge/map view (see week2_phase_d_agent_memory.md's "Knowledge
        # map" note); this is the same idea on the agent-facing side.
        def all_exits
          @db.execute("SELECT * FROM room_exits")
        end

        # Rooms whose name matches, exactly first, then by substring — the
        # model is quoting a room name it read in prose, so it will get the
        # case and the leading article wrong sooner or later.
        def find_rooms_by_name(name)
          needle = name.to_s.strip
          return [] if needle.empty?

          @db.execute(
            "SELECT * FROM rooms WHERE name = ? COLLATE NOCASE " \
            "UNION " \
            "SELECT * FROM rooms WHERE name LIKE ? COLLATE NOCASE AND name <> ? COLLATE NOCASE " \
            "ORDER BY name",
            [needle, "%#{needle}%", needle]
          )
        end

        # Shortest known route between two rooms, as an array of
        # { direction:, room_id:, name: } steps, or nil if no path is known.
        # [] means from == to.
        #
        # Breadth-first over `room_exits` where target_room_id IS NOT NULL —
        # which is exactly "edges the agent has actually walked", since that
        # column stays NULL until it has stood in the destination. So this
        # answers "can I get there by a route I already know?", never "does
        # the world contain a path?" A frontier is not a route.
        #
        # Unweighted: every MUD step costs one move, so BFS gives a genuine
        # shortest path with no need for Dijkstra.
        def route_to(from_id:, to_id:)
          from_id = from_id.to_i
          to_id   = to_id.to_i
          return [] if from_id == to_id
          return nil if from_id.zero? || to_id.zero?

          adjacency = Hash.new { |h, k| h[k] = [] }
          all_exits.each do |exit|
            target = exit["target_room_id"]
            next if target.nil?

            adjacency[exit["room_id"]] << { direction: exit["direction"], room_id: target }
          end

          queue   = [from_id]
          came_by = { from_id => nil } # room_id => { direction:, from: }

          until queue.empty?
            current = queue.shift
            adjacency[current].each do |edge|
              nxt = edge[:room_id]
              next if came_by.key?(nxt)

              came_by[nxt] = { direction: edge[:direction], from: current }
              return build_path(came_by, to_id) if nxt == to_id

              queue << nxt
            end
          end

          nil
        end

        private

        # Walk the BFS predecessor map back from the destination, then
        # reverse — the path is discovered end-first.
        def build_path(came_by, to_id)
          steps = []
          cursor = to_id
          while (link = came_by[cursor])
            steps << { direction: link[:direction], room_id: cursor, name: find_room(cursor)&.[]("name") }
            cursor = link[:from]
          end
          steps.reverse
        end

        def apply_pragmas!
          @db.execute("PRAGMA journal_mode = WAL")
          @db.execute("PRAGMA synchronous = NORMAL")
          @db.execute("PRAGMA foreign_keys = ON")
          @db.execute("PRAGMA busy_timeout = 5000")
        end

        def migrate!
          current = @db.get_first_value("PRAGMA user_version").to_i
          return if current >= Schema::VERSION

          @db.transaction do
            (current + 1..Schema::VERSION).each do |version|
              @db.execute_batch(Schema::STEPS.fetch(version))
            end
            @db.execute("PRAGMA user_version = #{Schema::VERSION}")
          end
        end

        def now_iso
          Time.now.iso8601(3)
        end
      end
    end
  end
end
