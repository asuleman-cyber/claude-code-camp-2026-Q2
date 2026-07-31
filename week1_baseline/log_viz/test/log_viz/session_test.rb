require "minitest/autorun"
require "tmpdir"
require "log_viz/session"

module LogViz
  class SessionTest < Minitest::Test
    def write_jsonl(*lines)
      dir  = Dir.mktmpdir
      path = File.join(dir, "test-session.jsonl")
      File.write(path, lines.join("\n"))
      path
    end

    def session_start(overrides = {})
      { "phase" => "session_start", "at" => "2026-07-31T00:00:00Z",
        "max_iterations" => 10, "max_turn_tokens" => 100_000,
        "context_window" => 200_000 }.merge(overrides).to_json
    end

    def turn(n) = { "phase" => "turn", "n" => n }.to_json
    def iteration(n) = { "phase" => "iteration", "n" => n }.to_json

    def prompt(text)
      { "phase" => "prompt", "messages" => [{ "role" => "user", "content" => text }] }.to_json
    end

    def response(overrides = {})
      { "phase" => "response", "text" => "ok", "usage" => { "input_tokens" => 100, "output_tokens" => 50 },
        "input_tokens" => 100, "output_tokens" => 50, "task" => "build", "provider" => "anthropic",
        "model" => "claude-sonnet-4-6", "cost_usd" => 0.001 }.merge(overrides).to_json
    end

    def turn_end(overrides = {})
      { "phase" => "turn_end", "reason" => "completed", "iterations" => 1, "tokens" => 150 }.merge(overrides).to_json
    end

    def test_parses_basic_session
      path = write_jsonl(
        session_start,
        turn(0), iteration(1), prompt("do the thing"), response, turn_end
      )
      session = Session.load(path)

      assert_equal "do the thing", session.task
      assert_equal 100, session.total_input_tokens
      assert_equal 50, session.total_output_tokens
      assert_equal 1, session.iteration_count
      assert_equal "completed", session.end_reason
      refute session.stopped?
      assert_empty session.parse_errors
      assert_nil session.fatal_error
    end

    def test_cost_prefers_logger_supplied_cost_usd
      path = write_jsonl(session_start, turn(0), iteration(1), prompt("x"), response("cost_usd" => 0.05), turn_end)
      session = Session.load(path)

      assert_in_delta 0.05, session.estimated_cost, 0.0001
    end

    def test_cost_falls_back_to_model_prices_when_unknown
      path = write_jsonl(
        session_start,
        turn(0), iteration(1), prompt("x"),
        response("cost_usd" => nil, "model" => "claude-sonnet-4-6"),
        turn_end
      )
      session = Session.load(path)

      # 100 input @ $3/MTok + 50 output @ $15/MTok
      expected = (100 * 3.0 / 1_000_000) + (50 * 15.0 / 1_000_000)
      assert_in_delta expected, session.estimated_cost, 0.0000001
    end

    def test_cost_nil_for_unknown_model_and_no_cost_usd
      path = write_jsonl(
        session_start,
        turn(0), iteration(1), prompt("x"),
        response("cost_usd" => nil, "model" => "some-mystery-model"),
        turn_end
      )
      session = Session.load(path)

      assert_nil session.estimated_cost
    end

    def test_stopped_reflects_non_completed_end_reason
      path = write_jsonl(
        session_start, turn(0), iteration(1), prompt("x"), response,
        turn_end("reason" => "max_iterations")
      )
      session = Session.load(path)

      assert session.stopped?
      assert session.any_limit_tripped?
    end

    def test_malformed_line_is_skipped_and_recorded_without_losing_the_rest
      path = write_jsonl(
        session_start,
        turn(0), iteration(1), prompt("x"),
        "{not valid json",
        response, turn_end
      )
      session = Session.load(path)

      assert_equal 1, session.parse_errors.length
      assert_equal 5, session.parse_errors.first[:line]
      assert_nil session.fatal_error
      # the rest of the file still parses fine
      assert_equal 100, session.total_input_tokens
      assert_equal "completed", session.end_reason
    end

    def test_blank_lines_are_ignored
      path = write_jsonl(session_start, "", turn(0), iteration(1), prompt("x"), response, turn_end)
      session = Session.load(path)

      assert_empty session.parse_errors
      assert_equal 100, session.total_input_tokens
    end

    def test_load_of_missing_file_sets_fatal_error_instead_of_raising
      session = Session.load(File.join(Dir.mktmpdir, "does-not-exist.jsonl"))

      refute_nil session.fatal_error
      assert_empty session.entries
      assert_empty session.parse_errors
    end

    def test_light_mode_keeps_index_page_data_but_drops_heavy_entries
      path = write_jsonl(
        session_start,
        turn(0), iteration(1), prompt("do the thing"),
        { "phase" => "tool_call", "name" => "roll_dice", "args" => {} }.to_json,
        { "phase" => "tool_result", "name" => "roll_dice", "result" => "x" * 10_000, "ok" => true }.to_json,
        { "phase" => "reasoning", "text" => "thinking..." }.to_json,
        response, turn_end
      )

      light = Session.load(path, light: true)
      full  = Session.load(path, light: false)

      # Heavy entry types are dropped in light mode...
      assert_empty light.entries.select { |e| e.type == :tool }
      assert_empty light.entries.select { |e| e.type == :reasoning }
      assert_empty light.entries.select { |e| e.type == :assistant }
      # ...but :user and :turn_end (needed by the index page) survive.
      assert_equal 1, light.entries.count { |e| e.type == :user }
      assert_equal 1, light.entries.count { |e| e.type == :turn_end }

      # and full mode still has everything.
      assert_equal 1, full.entries.count { |e| e.type == :tool }
      assert_equal 1, full.entries.count { |e| e.type == :reasoning }

      # summary figures used by the index page match between modes.
      assert_equal full.task, light.task
      assert_equal full.total_input_tokens, light.total_input_tokens
      assert_equal full.iteration_count, light.iteration_count
      assert_equal full.estimated_cost, light.estimated_cost
      assert_equal full.any_limit_tripped?, light.any_limit_tripped?
    end
  end
end
