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

    def test_telnet_page_filters_by_direction
      File.write(File.join(@telnet_dir, "#{Time.now.strftime("%Y%m%d")}.jsonl"),
                 [{ seq: 0, dir: "out", text: "look", bytes: 4 }.to_json,
                  { seq: 1, dir: "in", text: "The Common Square", bytes: 18 }.to_json].join("\n"))

      get "/telnet", dir: "in"

      assert_includes last_response.body, "The Common Square"
      refute_includes last_response.body, ">look<"
    end
  end
end
