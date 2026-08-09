require_relative "helper"
require "tmpdir"
require "set"

# Agent#run wraps its body in Logger#in_span (see agent.rb). That refactor
# turned the loop's early `return`s into `break`s so the value still exits
# through the span correctly. Agent also opens a child span per model round
# trip (boukensha.model_call) and per tool dispatch (boukensha.tool_call) —
# nested under the turn span so a trace renders as an actual waterfall
# instead of one bar with a flat event list (see docs/plans/otel_integration_plan.md's
# status note). These tests exist because none of that control flow had
# prior coverage, and they're the cheapest way to prove the nesting is real
# — parent tracked, not just "some spans got opened."
class TestAgentTelemetry < Minitest::Test
  include McpTestHelper

  # Records every in_span call (with its parent, via a stack) and every
  # event, without touching the real OpenTelemetry SDK — the same role
  # Telemetry::Noop plays in production, just with visibility for
  # assertions.
  class RecordingTelemetry
    Span = Struct.new(:name, :attributes, :parent)

    attr_reader :spans, :events

    def initialize
      @spans  = []
      @events = []
      @stack  = []
    end

    def in_span(name, attributes: {})
      span = Span.new(name, attributes, @stack.last)
      @spans << span
      @stack.push(span)
      yield
    ensure
      @stack.pop
    end

    def capture_event(event) = @events << event
    def current_ids = {}
    def force_flush(timeout: nil); end
    def shutdown(timeout: nil); end
  end

  FakeBackend = Struct.new(:responses) do
    def model = "fake-model"

    def parse_response(_response) = responses.shift
  end

  FakeClient = Struct.new(:raw_responses) do
    def call(**_opts) = raw_responses.shift
  end

  def test_normal_completion_opens_a_turn_span_with_one_nested_model_call
    telemetry = RecordingTelemetry.new
    backend   = FakeBackend.new([
      { stop_reason: "end_turn", content: [{ "type" => "text", "text" => "done" }] }
    ])
    result = run_agent(telemetry: telemetry, backend: backend, raw_responses: [{ "usage" => {} }])

    assert_equal "done", result
    assert_equal ["boukensha.turn", "boukensha.model_call"], telemetry.spans.map(&:name)

    turn, model_call = telemetry.spans
    assert_nil turn.parent
    assert_equal Set["boukensha.session_id"], turn.attributes.keys.to_set
    assert_equal turn, model_call.parent
    assert_equal 1, model_call.attributes["boukensha.iteration"]
  end

  def test_max_iterations_wrap_up_nests_model_and_tool_spans_under_one_turn
    telemetry = RecordingTelemetry.new
    backend   = FakeBackend.new([
      { stop_reason: "tool_use", content: [{ "type" => "tool_use", "name" => "nope", "input" => {}, "id" => "1" }] },
      { stop_reason: "end_turn", content: [{ "type" => "text", "text" => "wrapped up" }] }
    ])
    result = run_agent(
      telemetry: telemetry, backend: backend,
      raw_responses: [{ "usage" => {} }, { "usage" => {} }],
      max_iterations: 1
    )

    assert_equal "wrapped up", result
    # One turn span; the iteration's model call, the failed tool dispatch,
    # and the wrap-up's own model call are all its direct children — this
    # is what makes the trace render as a waterfall (three sibling bars
    # under one turn bar) instead of a flat, un-timed event list.
    assert_equal(
      ["boukensha.turn", "boukensha.model_call", "boukensha.tool_call", "boukensha.model_call"],
      telemetry.spans.map(&:name)
    )
    turn = telemetry.spans.first
    assert telemetry.spans[1..].all? { |span| span.parent == turn }

    tool_call = telemetry.spans[2]
    assert_equal "nope", tool_call.attributes["boukensha.tool.name"]

    wrap_up_call = telemetry.spans[3]
    assert_equal true, wrap_up_call.attributes["boukensha.wrap_up"]

    assert_includes telemetry.events.map { |e| e[:phase] }, "limit_reached"
  end

  private

  def run_agent(telemetry:, backend:, raw_responses:, max_iterations: Boukensha::Agent::MAX_ITERATIONS)
    Dir.mktmpdir do |dir|
      context  = Boukensha::Context.new(system: "test")
      builder  = Boukensha::PromptBuilder.new(context, backend)
      client   = FakeClient.new(raw_responses)
      logger   = Boukensha::Logger.new(dir: dir, telemetry: telemetry)
      registry = Boukensha::Registry.new(context)
      agent    = Boukensha::Agent.new(
        context: context, registry: registry, builder: builder, client: client,
        logger: logger, max_iterations: max_iterations
      )
      context.add_message(:user, "go")
      agent.run
    ensure
      logger&.close
    end
  end
end
