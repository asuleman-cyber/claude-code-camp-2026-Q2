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

    # otel.md Phase 3: Boukensha::Logger stamps trace_id/span_id onto every
    # line written while a telemetry span is open (see
    # Boukensha::Telemetry#current_ids). Session just needs to carry those
    # two fields through onto the Entry so the view can link to the trace.
    def test_trace_id_and_span_id_carry_through_when_present
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1),
        prompt("do the thing", "trace_id" => "abc123", "span_id" => "def456"),
        response("trace_id" => "abc123", "span_id" => "ghi789"),
        turn_end
      ))

      user_entry      = session.entries.find { |e| e.type == :user }
      assistant_entry = session.entries.find { |e| e.type == :assistant }

      assert_equal "abc123", user_entry.trace_id
      assert_equal "def456", user_entry.span_id
      assert_equal "abc123", assistant_entry.trace_id
      assert_equal "ghi789", assistant_entry.span_id
    end

    def test_trace_id_and_span_id_are_nil_when_tracing_was_off
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1), prompt("do the thing"), response, turn_end
      ))

      user_entry = session.entries.find { |e| e.type == :user }

      assert_nil user_entry.trace_id
      assert_nil user_entry.span_id
    end

    # ---- Phase G: the orchestrator's own events -------------------------

    def orchestrator(overrides = {})
      { "phase" => "orchestrator", "at" => "2026-07-31T00:00:02.000Z", "mono_ms" => 3000,
        "role" => "judge", "event" => "verdict", "detail" => "continue",
        "text" => "Making steady progress." }.merge(overrides).to_json
    end

    def test_parses_an_orchestrator_verdict
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1), prompt("explore"), response,
        orchestrator, turn_end
      ))

      entry = session.entries.find { |e| e.type == :orchestrator }

      refute_nil entry
      assert_equal "judge",    entry.task
      assert_equal "verdict",  entry.reason
      assert_equal "continue", entry.stop_reason
      assert_equal "Making steady progress.", entry.text
    end

    def test_parses_a_planner_event_without_text
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1),
        orchestrator("role" => "planner", "event" => "start", "detail" => "explore north", "text" => nil),
        prompt("explore"), response, turn_end
      ))

      entry = session.entries.find { |e| e.type == :orchestrator }

      assert_equal "planner", entry.task
      assert_equal "start",   entry.reason
      assert_nil entry.text
    end

    # The transcript labels each message with the role that produced it, so a
    # Planner/Player/Judge session can be read apart. That comes from the
    # `task` field the logger already carried.
    def test_assistant_entries_carry_their_task
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1), prompt("explore"),
        response("task" => "judge"), turn_end
      ))

      assert_equal "judge", session.entries.find { |e| e.type == :assistant }.task
    end

    # A subagent's request is also a `prompt` event, and the Planner's fires
    # between `turn` and the Player's own first prompt. Without the task
    # guard the transcript would show the Planner's brief (goal + memory
    # digest) where the user's real input belongs — and then drop the real
    # one, because pending_user was already consumed.
    def test_a_planner_prompt_does_not_hijack_the_turns_user_entry
      session = Session.load(write_jsonl(
        session_start, turn(0),
        prompt("Memory: ...\n---\nThe goal: explore", "task" => "planner"),
        iteration(1),
        prompt("explore the temple"),
        response, turn_end
      ))

      users = session.entries.select { |e| e.type == :user }

      assert_equal 1, users.size, "exactly one user entry per turn"
      assert_equal "explore the temple", users.first.text
    end

    def test_a_chronicler_prompt_is_also_ignored_as_user_input
      session = Session.load(write_jsonl(
        session_start, turn(0),
        prompt("distil this session", "task" => "chronicler"),
        iteration(1), prompt("go north"), response, turn_end
      ))

      assert_equal ["go north"], session.entries.select { |e| e.type == :user }.map(&:text)
    end

    # Context#messages appends the state block as a synthetic trailing *user*
    # message, and Mud::Hooks sets it before Logger#prompt runs — so the raw
    # `.last` is the state block, not what anyone said. Pre-existing since
    # Phase D; every hooked session rendered the state block as the user's
    # input until this was fixed.
    def test_the_state_block_is_not_mistaken_for_user_input
      path = write_jsonl(
        session_start, turn(0), iteration(1),
        { "phase" => "prompt", "at" => "2026-07-31T00:00:00.100Z", "mono_ms" => 1100,
          "task" => "player", "synthetic_tail" => true,
          "messages" => [
            { "role" => "user", "content" => "go to the temple" },
            { "role" => "user", "content" => "[here] Poor Alley\nexits: east" }
          ] }.to_json,
        response, turn_end
      )

      users = Session.load(path).entries.select { |e| e.type == :user }
      assert_equal ["go to the temple"], users.map(&:text)
    end

    # Logs written before `synthetic_tail` existed still render correctly, via
    # the "[here]" fallback.
    def test_a_pre_fix_log_still_finds_the_real_user_input
      path = write_jsonl(
        session_start, turn(0), iteration(1),
        { "phase" => "prompt", "at" => "2026-07-31T00:00:00.100Z", "mono_ms" => 1100,
          "messages" => [
            { "role" => "user", "content" => "go to the temple" },
            { "role" => "user", "content" => "[here] Poor Alley\nexits: east" }
          ] }.to_json,
        response, turn_end
      )

      users = Session.load(path).entries.select { |e| e.type == :user }
      assert_equal ["go to the temple"], users.map(&:text)
    end

    # A turn with no state block (hooks off) is untouched by any of this.
    def test_no_state_block_means_the_last_message_is_the_input
      path = write_jsonl(
        session_start, turn(0), iteration(1),
        { "phase" => "prompt", "at" => "2026-07-31T00:00:00.100Z", "mono_ms" => 1100,
          "task" => "player", "synthetic_tail" => false,
          "messages" => [{ "role" => "user", "content" => "go north" }] }.to_json,
        response, turn_end
      )

      assert_equal ["go north"], Session.load(path).entries.select { |e| e.type == :user }.map(&:text)
    end

    # An explicit player tag behaves exactly like an untagged prompt.
    def test_a_player_tagged_prompt_still_opens_the_turn
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1),
        prompt("go north", "task" => "player"), response, turn_end
      ))

      assert_equal ["go north"], session.entries.select { |e| e.type == :user }.map(&:text)
    end

    # A pre-Phase-G log has no orchestrator lines at all and must still parse.
    def test_sessions_without_orchestrator_events_are_unaffected
      session = Session.load(write_jsonl(
        session_start, turn(0), iteration(1), prompt("do the thing"), response, turn_end
      ))

      assert_empty session.entries.select { |e| e.type == :orchestrator }
    end
  end
end
