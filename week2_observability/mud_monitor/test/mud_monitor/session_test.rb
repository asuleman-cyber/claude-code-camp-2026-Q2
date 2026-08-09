require_relative "../helper"
require "tmpdir"
require "mud_monitor/session"

module MudMonitor
  class SessionTest < Minitest::Test
    def write_jsonl(*lines)
      dir  = Dir.mktmpdir
      path = File.join(dir, "test-session.jsonl")
      File.write(path, lines.join("\n"))
      path
    end

    def session_start(overrides = {})
      { "phase" => "session_start", "at" => "2026-07-31T00:00:00.000Z", "mono_ms" => 1000,
        "max_iterations" => 10, "max_turn_tokens" => 100_000,
        "context_window" => 200_000 }.merge(overrides).to_json
    end

    def turn(n) = { "phase" => "turn", "n" => n }.to_json
    def iteration(n) = { "phase" => "iteration", "n" => n }.to_json

    def prompt(text, overrides = {})
      { "phase" => "prompt", "at" => "2026-07-31T00:00:00.100Z", "mono_ms" => 1100,
        "messages" => [{ "role" => "user", "content" => text }] }.merge(overrides).to_json
    end

    def response(overrides = {})
      { "phase" => "response", "at" => "2026-07-31T00:00:01.600Z", "mono_ms" => 2600,
        "text" => "ok", "usage" => { "input_tokens" => 100, "output_tokens" => 50 },
        "input_tokens" => 100, "output_tokens" => 50, "task" => "build", "provider" => "anthropic",
        "model" => "claude-sonnet-4-6", "cost_usd" => 0.001 }.merge(overrides).to_json
    end

    def turn_end(overrides = {})
      { "phase" => "turn_end", "reason" => "completed", "iterations" => 1, "tokens" => 150 }.merge(overrides).to_json
    end

    def test_parses_basic_session
      path = Session.load(write_jsonl(
        session_start, turn(0), iteration(1), prompt("do the thing"), response, turn_end
      ))

      assert_equal "2026-07-31T00:00:00.000Z", path.started_at
      assert_equal 100, path.total_input_tokens
      assert_equal 50, path.total_output_tokens
      assert_equal "completed", path.end_reason
      refute path.stopped?
    end

    def test_dt_ms_uses_mono_ms_when_available
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1), prompt("do the thing"), response, turn_end
      ))

      user_entry      = session.entries.find { |e| e.type == :user }
      assistant_entry = session.entries.find { |e| e.type == :assistant }

      # prompt.mono_ms (1100) - session_start.mono_ms (1000) = 100
      assert_equal 100, user_entry.dt_ms
      # response.mono_ms (2600) - prompt.mono_ms (1100) = 1500
      assert_equal 1500, assistant_entry.dt_ms
      assert_equal "monotonic", session.timing_source
    end

    def test_timing_source_is_wallclock_coarse_for_pre_ms_logs
      old_start    = { "phase" => "session_start", "at" => "2026-07-31T00:00:00Z" }.to_json
      old_prompt   = { "phase" => "prompt", "at" => "2026-07-31T00:00:01Z",
                        "messages" => [{ "role" => "user", "content" => "hi" }] }.to_json
      session = Session.load(write_jsonl(old_start, turn(0), iteration(1), old_prompt))

      assert_equal "wallclock_coarse", session.timing_source
      user_entry = session.entries.find { |e| e.type == :user }
      assert_equal 1000, user_entry.dt_ms
    end

    def test_entries_with_neither_mono_ms_nor_at_have_nil_dt
      no_time_start = { "phase" => "session_start" }.to_json
      no_time_plan  = { "phase" => "plan", "text" => "go north" }.to_json
      session = Session.load(write_jsonl(no_time_start, turn(0), iteration(1), no_time_plan))

      plan_entry = session.entries.find { |e| e.type == :plan }
      assert_nil plan_entry.dt_ms
      assert_nil session.timing_source
    end

    def test_live_is_false_for_an_old_file
      path = write_jsonl(session_start)
      session = Session.load(path)
      File.utime(Time.now - 3600, Time.now - 3600, path)

      refute session.live?
    end

    def test_survives_a_corrupt_line
      path = write_jsonl(session_start, "{not valid json", turn(0))
      session = Session.load(path)

      assert_equal 1, session.parse_errors.length
      assert_equal 2, session.parse_errors.first[:line]
    end
  end
end
