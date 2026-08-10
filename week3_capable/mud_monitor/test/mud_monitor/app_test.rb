require_relative "../helper"
require "rack/test"
require "tmpdir"
require "json"
require "mud_monitor/app"

module MudMonitor
  class AppTest < Minitest::Test
    include Rack::Test::Methods

    def app
      MudMonitor::App
    end

    def setup
      # Sinatra's development-mode Rack::Protection::HostAuthorization only
      # permits localhost/IP hosts; Rack::Test's default request Host
      # ("example.org") isn't one, so run as production would (no host
      # allowlist) instead of poking Host headers on every request.
      MudMonitor::App.set :environment, :test
      @sessions_dir = Dir.mktmpdir
      @manager_dir  = Dir.mktmpdir
      @telnet_dir   = Dir.mktmpdir
      MudMonitor::App.set :sessions_dir, @sessions_dir
      MudMonitor::App.set :manager_dir, @manager_dir
      MudMonitor::App.set :telnet_dir, @telnet_dir
      MudMonitor::App.set :knowledge_db, File.join(Dir.mktmpdir, "knowledge.sqlite3") # absent by default
      MudMonitor::App.set :journal_dir, File.join(Dir.mktmpdir, "journal") # absent by default
      MudMonitor::App.set :error_log_path, File.join(Dir.mktmpdir, "error.log") # absent by default
    end

    def write_session(id, at:, task: "do a thing", model: "claude-sonnet-4-6", extra_lines: [])
      lines = [
        { "phase" => "session_start", "at" => at, "context_window" => 200_000 }.to_json,
        { "phase" => "turn", "n" => 0 }.to_json,
        { "phase" => "iteration", "n" => 1 }.to_json,
        { "phase" => "prompt", "messages" => [{ "role" => "user", "content" => task }] }.to_json,
        { "phase" => "response", "text" => "ok", "usage" => { "input_tokens" => 10, "output_tokens" => 5 },
          "input_tokens" => 10, "output_tokens" => 5, "task" => task, "provider" => "anthropic",
          "model" => model, "cost_usd" => 0.01 }.to_json,
        { "phase" => "turn_end", "reason" => "completed", "iterations" => 1, "tokens" => 15 }.to_json,
      ] + extra_lines
      File.write(File.join(@sessions_dir, "#{id}.jsonl"), lines.join("\n"))
    end

    def write_manager_record(record)
      date = Time.now.strftime("%Y%m%d")
      File.write(File.join(@manager_dir, "#{date}.jsonl"), JSON.generate(record) + "\n")
    end

    def write_telnet_record(record)
      date = Time.now.strftime("%Y%m%d")
      File.write(File.join(@telnet_dir, "#{date}.jsonl"), JSON.generate(record) + "\n")
    end

    # --- sessions (ported straight from log_viz) ---

    def test_index_lists_sessions
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z")
      write_session("2026-07-31-bbb", at: "2026-07-31T01:00:00Z")

      get "/"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "2026-07-31-aaa"
      assert_includes last_response.body, "2026-07-31-bbb"
    end

    def test_index_shows_empty_message_when_no_sessions
      get "/"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "No session logs found"
    end

    def test_session_detail_renders
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z")

      get "/sessions/2026-07-31-aaa"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "2026-07-31-aaa"
    end

    def test_session_detail_missing_id_is_404
      get "/sessions/does-not-exist"

      assert_equal 404, last_response.status
    end

    def test_session_detail_links_to_the_trace_when_present
      MudMonitor::App.set :jaeger_base_url, "http://localhost:16686"
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", extra_lines: [
        { "phase" => "response", "text" => "traced", "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
          "trace_id" => "abc123def456", "span_id" => "def456" }.to_json
      ])

      get "/sessions/2026-07-31-aaa"

      assert_includes last_response.body, %(href="http://localhost:16686/trace/abc123def456")
    end

    # Phase G. Renders the real ERB, so this is what catches a broken view —
    # session_test.rb only proves the JSONL parsed.
    def test_session_detail_renders_orchestrator_verdicts
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", extra_lines: [
        { "phase" => "orchestrator", "role" => "planner", "event" => "start",
          "detail" => "explore north" }.to_json,
        { "phase" => "orchestrator", "role" => "judge", "event" => "verdict",
          "detail" => "flag", "text" => "The character is stuck." }.to_json
      ])

      get "/sessions/2026-07-31-aaa"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "task-planner"
      assert_includes last_response.body, "task-judge"
      assert_includes last_response.body, "verdict-flag"
      assert_includes last_response.body, "The character is stuck."
    end

    # Phase I — the Navigator writes into the same transcript.
    def test_session_detail_renders_navigator_answers
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", extra_lines: [
        { "phase" => "orchestrator", "role" => "navigator", "event" => "answer",
          "text" => "north, east - 2 steps." }.to_json
      ])

      get "/sessions/2026-07-31-aaa"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "task-navigator"
      assert_includes last_response.body, "north, east - 2 steps."
    end

    # Phase J — the Chronicler's digest rewrites show in the transcript too.
    def test_session_detail_renders_chronicler_writes
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", extra_lines: [
        { "phase" => "orchestrator", "role" => "chronicler", "event" => "written",
          "detail" => "exit", "text" => "## Discoveries\nThe temple is north." }.to_json
      ])

      get "/sessions/2026-07-31-aaa"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "task-chronicler"
      assert_includes last_response.body, "The temple is north."
    end

    def test_session_detail_has_no_trace_link_when_tracing_was_off
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z")

      get "/sessions/2026-07-31-aaa"

      refute_includes last_response.body, "trace-link"
    end

    def test_session_detail_rejects_path_traversal
      get "/sessions/..%2F..%2F..%2Fetc%2Fpasswd"

      assert_equal 404, last_response.status
    end

    # --- manager log page ---

    def test_manager_page_shows_disabled_message_when_dir_absent
      MudMonitor::App.set :manager_dir, File.join(Dir.mktmpdir, "absent")

      get "/manager"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Not enabled"
    end

    def test_manager_page_lists_entries
      write_manager_record(seq: 0, mode: "command", tool: "look", received: "The Common Square", elapsed_ms: 12)

      get "/manager"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "look"
      assert_includes last_response.body, "The Common Square"
    end

    def test_manager_page_flags_errors
      write_manager_record(seq: 0, mode: "command", tool: "move", error: "argument_error: bad direction")

      get "/manager"

      assert_includes last_response.body, "argument_error"
    end

    # --- telnet log page ---

    def test_telnet_page_shows_disabled_message_when_dir_absent
      MudMonitor::App.set :telnet_dir, File.join(Dir.mktmpdir, "absent")

      get "/telnet"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Not enabled"
    end

    def test_telnet_page_lists_entries_and_redacts
      write_telnet_record(seq: 0, dir: "out", text: "look", bytes: 4)

      get "/telnet"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "look"
    end

    def test_telnet_page_never_renders_a_redacted_payload
      write_telnet_record(seq: 0, dir: "out", text: "<redacted>", bytes: 9, redacted: true)

      get "/telnet"

      assert_includes last_response.body, "redacted"
      refute_includes last_response.body, "helloworld"
    end

    def test_telnet_page_shows_a_stalled_note_when_the_log_has_gone_quiet
      path = File.join(@telnet_dir, "#{Time.now.strftime("%Y%m%d")}.jsonl")
      File.write(path, { seq: 0, dir: "out", text: "look", bytes: 4, at: "2026-08-06T01:17:14Z" }.to_json)
      old = Time.now - 3600
      File.utime(old, old, path) # older than TelnetLogStore::LIVE_WINDOW_SECONDS -> not live

      get "/telnet"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "No new traffic since"
    end

    def test_telnet_page_lists_entries_and_redacts_shows_no_stalled_note_when_live
      write_telnet_record(seq: 0, dir: "out", text: "look", bytes: 4, at: "2026-08-06T01:17:14Z")

      get "/telnet"

      refute_includes last_response.body, "No new traffic since"
    end

    def test_telnet_page_filters_by_direction
      File.write(File.join(@telnet_dir, "#{Time.now.strftime("%Y%m%d")}.jsonl"),
                 [{ seq: 0, dir: "out", text: "look", bytes: 4 }.to_json,
                  { seq: 1, dir: "in", text: "The Common Square", bytes: 18 }.to_json].join("\n"))

      get "/telnet", dir: "in"

      assert_includes last_response.body, "The Common Square"
      refute_includes last_response.body, ">look<"
    end

    # --- knowledge page (Phase D) ---

    def test_knowledge_page_shows_disabled_message_when_db_absent
      get "/knowledge"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "No"
    end

    def test_knowledge_page_lists_rooms_and_entities
      db_path = File.join(Dir.mktmpdir, "knowledge.sqlite3")
      require "sqlite3"
      db = SQLite3::Database.new(db_path)
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
        INSERT INTO rooms VALUES (1, 'fp1', NULL, 'Market Square', 'busy', '2026-01-01', '2026-01-02', 1, '2026-01-01');
        INSERT INTO entities VALUES (1, 'mob', 'A cityguard stands here.', 'cityguard', 'Easy.', 1, 'excellent', 1, '2026-01-01', '2026-01-02');
      SQL
      db.close
      MudMonitor::App.set :knowledge_db, db_path

      get "/knowledge"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Market Square"
      assert_includes last_response.body, "cityguard"
    end

    def test_knowledge_room_detail_404s_for_unknown_id
      get "/knowledge/rooms/999"
      assert_equal 404, last_response.status
    end

    def test_knowledge_player_page_shows_disabled_message_when_db_absent
      get "/knowledge/player"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "No"
    end

    def test_knowledge_player_page_shows_score_inventory_and_equipment
      db_path = File.join(Dir.mktmpdir, "knowledge.sqlite3")
      require "sqlite3"
      db = SQLite3::Database.new(db_path)
      db.execute_batch(<<~SQL)
        CREATE TABLE rooms (id INTEGER PRIMARY KEY, name TEXT, last_seen_at TEXT);
        CREATE TABLE player_state (id INTEGER PRIMARY KEY, current_room_id INTEGER, hp INTEGER, max_hp INTEGER,
          age INTEGER, armor_class TEXT, updated_at TEXT);
        CREATE TABLE player_inventory (id INTEGER PRIMARY KEY, descr TEXT, keyword TEXT, quantity INTEGER,
          first_seen_at TEXT, last_seen_at TEXT);
        CREATE TABLE player_equipment (id INTEGER PRIMARY KEY, slot TEXT, descr TEXT, keyword TEXT,
          first_seen_at TEXT, last_seen_at TEXT);
        INSERT INTO rooms VALUES (1, 'Market Square', '2026-01-01');
        INSERT INTO player_state VALUES (1, 1, 20, 20, 18, '39/10', '2026-01-02');
        INSERT INTO player_inventory VALUES (1, 'a torch', 'torch', 1, '2026-01-01', '2026-01-02');
        INSERT INTO player_equipment VALUES (1, 'wielded', 'a small sword', 'sword', '2026-01-01', '2026-01-02');
      SQL
      db.close
      MudMonitor::App.set :knowledge_db, db_path

      get "/knowledge/player"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Market Square"
      assert_includes last_response.body, "a torch"
      assert_includes last_response.body, "a small sword"
      assert_includes last_response.body, "39/10"
    end

    def test_knowledge_map_page_shows_disabled_message_when_db_absent
      get "/knowledge/map"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "No"
    end

    def test_knowledge_map_page_positions_rooms_and_highlights_the_current_one
      db_path = File.join(Dir.mktmpdir, "knowledge.sqlite3")
      require "sqlite3"
      db = SQLite3::Database.new(db_path)
      db.execute_batch(<<~SQL)
        CREATE TABLE rooms (id INTEGER PRIMARY KEY, name TEXT, first_seen_at TEXT, last_seen_at TEXT);
        CREATE TABLE room_exits (room_id INTEGER, direction TEXT, target_room_id INTEGER);
        CREATE TABLE player_state (id INTEGER PRIMARY KEY, current_room_id INTEGER);
        INSERT INTO rooms VALUES (1, 'Market Square', '2026-01-01', '2026-01-01');
        INSERT INTO rooms VALUES (2, 'Temple Square', '2026-01-02', '2026-01-02');
        INSERT INTO room_exits VALUES (1, 'north', 2);
        INSERT INTO player_state VALUES (1, 1);
      SQL
      db.close
      MudMonitor::App.set :knowledge_db, db_path

      get "/knowledge/map"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Market Square"
      assert_includes last_response.body, "Temple Square"
      assert_includes last_response.body, "current"
      assert_includes last_response.body, "connected-north"
      # Legend/summary panel (player_map_plan.md redesign follow-up).
      assert_includes last_response.body, "2 rooms"
      assert_includes last_response.body, "1 connection"
      assert_includes last_response.body, "connected exit"
    end

    def test_knowledge_map_page_lists_disconnected_rooms_as_a_table
      db_path = File.join(Dir.mktmpdir, "knowledge.sqlite3")
      require "sqlite3"
      db = SQLite3::Database.new(db_path)
      db.execute_batch(<<~SQL)
        CREATE TABLE rooms (id INTEGER PRIMARY KEY, name TEXT, first_seen_at TEXT, last_seen_at TEXT,
          visit_count INTEGER, surveyed_at TEXT);
        CREATE TABLE room_exits (room_id INTEGER, direction TEXT, target_room_id INTEGER);
        CREATE TABLE player_state (id INTEGER PRIMARY KEY, current_room_id INTEGER);
        INSERT INTO rooms VALUES (1, 'Market Square', '2026-01-01', '2026-01-01', 1, '2026-01-01');
        INSERT INTO rooms VALUES (2, 'Hidden Grove', '2026-01-02', '2026-01-02', 1, NULL);
      SQL
      db.close
      MudMonitor::App.set :knowledge_db, db_path

      get "/knowledge/map"

      assert_includes last_response.body, "Disconnected"
      assert_includes last_response.body, %(class="log-table")
      assert_includes last_response.body, "Hidden Grove"
    end

    # --- Knowledge/Player/Map share a tab strip, not an inline text link ---

    def test_knowledge_family_pages_share_an_active_tab_strip
      %w[/knowledge /knowledge/player /knowledge/map].each do |path|
        get path
        assert_includes last_response.body, %(class="subnav")
      end

      get "/knowledge"
      assert_includes last_response.body, %(<a href="/knowledge" class="active">Overview</a>)

      get "/knowledge/player"
      assert_includes last_response.body, %(<a href="/knowledge/player" class="active">Player</a>)

      get "/knowledge/map"
      assert_includes last_response.body, %(<a href="/knowledge/map" class="active">Map</a>)
    end

    # --- progression page (Phase E) ---

    def test_progression_page_shows_disabled_message_when_dir_absent
      get "/progression"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Not enabled"
    end

    def test_progression_page_lists_changes
      dir = File.join(Dir.mktmpdir, "journal")
      Dir.mkdir(dir)
      File.write(File.join(dir, "#{Time.now.strftime("%Y%m%d")}.jsonl"),
                 { seq: 1, at: Time.now.iso8601, stream: "player", key: "hp", from: 20, to: 15 }.to_json)
      MudMonitor::App.set :journal_dir, dir

      get "/progression"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "hp"
    end

    # --- errors page (Phase F) ---

    def test_errors_page_shows_empty_message_when_log_absent
      get "/errors"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "No"
    end

    def test_errors_page_lists_errors
      path = File.join(Dir.mktmpdir, "error.log")
      File.write(path, { at: Time.now.iso8601, error_class: "RuntimeError", message: "boom", backtrace: ["a.rb:1"] }.to_json)
      MudMonitor::App.set :error_log_path, path

      get "/errors"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "RuntimeError"
      assert_includes last_response.body, "boom"
    end
  end
end
