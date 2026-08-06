module Boukensha
  module Mud
    module Memory
      # Versioned DDL, applied via PRAGMA user_version — not ActiveRecord,
      # not a migrations gem. Store.migrate! reads the current version and
      # applies every numbered step above it in one transaction. No
      # dependency, and it can never collide with a Rails migrations table
      # because there isn't one (mud_monitor reads this file read-only).
      #
      # Trimmed from the source plan's 5-table design
      # (docs/plans/week_2/basic_memory.md §3) — no `encounters` table (its
      # own doc calls it "Phase 3") and no `look_candidates` column (that
      # field was already dropped from RoomParser in Phase C). Everything
      # else — the non-UNIQUE fingerprint, the entities/sightings split, the
      # single-row player_state — matches the source design; see this
      # gem's docs/... report for the one identity simplification made
      # (weak-fingerprint-only lookup, no arrival-edge disambiguation).
      module Schema
        VERSION = 1

        STEPS = {
          1 => <<~SQL
            -- Permanent world data, one row per room the agent has stood in.
            -- weak_fingerprint is NOT UNIQUE, deliberately: two different
            -- rooms could in principle share one, and identity is always
            -- `id`, never the fingerprint. See basic_memory.md §4.
            CREATE TABLE rooms (
              id                 INTEGER PRIMARY KEY,
              weak_fingerprint   TEXT NOT NULL,
              strong_fingerprint TEXT,
              name               TEXT NOT NULL,
              description        TEXT NOT NULL,
              first_seen_at      TEXT NOT NULL,
              last_seen_at       TEXT NOT NULL,
              visit_count        INTEGER NOT NULL DEFAULT 1,
              surveyed_at        TEXT
            );
            CREATE INDEX idx_rooms_weak ON rooms(weak_fingerprint);
            CREATE INDEX idx_rooms_name ON rooms(name);

            -- The map. One row per (room, direction). target_room_id is
            -- NULL until the agent has actually stood in the destination —
            -- that NULL *is* the exploration frontier.
            CREATE TABLE room_exits (
              room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
              direction      TEXT NOT NULL,
              target_name    TEXT,
              target_room_id INTEGER REFERENCES rooms(id),
              traversals     INTEGER NOT NULL DEFAULT 0,
              last_seen_at   TEXT NOT NULL,
              PRIMARY KEY (room_id, direction)
            );
            CREATE INDEX idx_exits_frontier ON room_exits(target_room_id) WHERE target_room_id IS NULL;

            -- A mob/object TYPE, stored once for the whole world — "A
            -- cityguard stands here." is one row no matter how many rooms
            -- it patrols, which is what makes appraisal reusable: a
            -- cityguard met in a brand-new room costs zero
            -- consider/examine round trips once this row exists.
            CREATE TABLE entities (
              id            INTEGER PRIMARY KEY,
              kind          TEXT NOT NULL CHECK (kind IN ('mob','object')),
              descr         TEXT NOT NULL,
              keyword       TEXT,
              threat        TEXT,
              threat_level  INTEGER,
              health        TEXT,
              seen_count    INTEGER NOT NULL DEFAULT 1,
              first_seen_at TEXT NOT NULL,
              last_seen_at  TEXT NOT NULL,
              UNIQUE (kind, descr)
            );

            -- Where a type has been seen, and how recently.
            CREATE TABLE entity_sightings (
              entity_id      INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
              room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
              count          INTEGER NOT NULL DEFAULT 1,
              sighting_count INTEGER NOT NULL DEFAULT 1,
              first_seen_at  TEXT NOT NULL,
              last_seen_at   TEXT NOT NULL,
              PRIMARY KEY (entity_id, room_id)
            );
            CREATE INDEX idx_sightings_room ON entity_sightings(room_id);

            -- Exactly one row.
            CREATE TABLE player_state (
              id              INTEGER PRIMARY KEY CHECK (id = 1),
              current_room_id INTEGER REFERENCES rooms(id),
              prev_room_id    INTEGER REFERENCES rooms(id),
              last_direction  TEXT,
              hp INTEGER, max_hp INTEGER,
              mana INTEGER, move INTEGER,
              level INTEGER, gold INTEGER, exp INTEGER,
              position        TEXT,
              session_id      TEXT,
              updated_at      TEXT NOT NULL
            );
          SQL
        }.freeze
      end
    end
  end
end
