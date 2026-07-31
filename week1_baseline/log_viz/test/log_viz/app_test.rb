require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "json"
require "log_viz/app"

module LogViz
  class AppTest < Minitest::Test
    include Rack::Test::Methods

    def app
      LogViz::App
    end

    def setup
      # Sinatra's development-mode Rack::Protection::HostAuthorization only
      # permits localhost/IP hosts; Rack::Test's default request Host
      # ("example.org") isn't one, so run the app as it would in production
      # (no host allowlist) instead of poking Host headers on every request.
      LogViz::App.set :environment, :test
      @sessions_dir = Dir.mktmpdir
      LogViz::App.set :sessions_dir, @sessions_dir
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

    def test_index_survives_one_corrupt_log
      write_session("2026-07-31-good", at: "2026-07-31T00:00:00Z")
      File.write(File.join(@sessions_dir, "2026-07-31-bad.jsonl"), "{not valid json\n")

      get "/"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "2026-07-31-good"
      assert_includes last_response.body, "2026-07-31-bad"
    end

    def test_index_filters_by_query
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", task: "fix the parser")
      write_session("2026-07-31-bbb", at: "2026-07-31T01:00:00Z", task: "write docs")

      get "/", q: "parser"

      assert_includes last_response.body, "2026-07-31-aaa"
      refute_includes last_response.body, "2026-07-31-bbb"
    end

    def test_index_filters_by_model
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", model: "claude-sonnet-4-6")
      write_session("2026-07-31-bbb", at: "2026-07-31T01:00:00Z", model: "claude-opus-4-8")

      get "/", model: "claude-opus-4-8"

      assert_includes last_response.body, "2026-07-31-bbb"
      refute_includes last_response.body, "2026-07-31-aaa"
    end

    def test_index_paginates
      30.times { |i| write_session(format("2026-07-31-s%02d", i), at: "2026-07-31T00:%02d:00Z" % i) }

      get "/"
      assert_includes last_response.body, "Page 1 of 2"

      get "/", page: "2"
      assert_includes last_response.body, "Page 2 of 2"
    end

    def test_index_search_box_escapes_html_in_query
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z")

      get "/", q: %(<script>alert(1)</script>)

      refute_includes last_response.body, "<script>alert(1)</script>"
      assert_includes last_response.body, "&lt;script&gt;"
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

    def test_session_detail_shows_parse_error_banner
      write_session("2026-07-31-aaa", at: "2026-07-31T00:00:00Z", extra_lines: ["{not valid json"])

      get "/sessions/2026-07-31-aaa"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "could not be parsed"
    end
  end
end
