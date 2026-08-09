require_relative "helper"
require "stringio"
require "tmpdir"
require "json"

class TestTelemetryConfig < Minitest::Test
  include McpTestHelper

  def test_otel_disabled_by_default
    config_from("") { |cfg| refute cfg.otel_enabled? }
  end

  def test_otel_enabled_via_yaml
    yaml = <<~YAML
      observability:
        otel:
          enabled: true
    YAML
    config_from(yaml) { |cfg| assert cfg.otel_enabled? }
  end

  def test_env_var_overrides_yaml_in_both_directions
    yaml = <<~YAML
      observability:
        otel:
          enabled: true
    YAML
    with_env("BOUKENSHA_OTEL_ENABLED" => "false") do
      config_from(yaml) { |cfg| refute cfg.otel_enabled? }
    end
  end

  def test_content_max_bytes_defaults_to_4096
    config_from("") { |cfg| assert_equal 4096, cfg.otel_content_max_bytes }
  end

  def test_content_max_bytes_rejects_non_positive
    yaml = <<~YAML
      observability:
        otel:
          content_max_bytes: 0
    YAML
    config_from(yaml) { |cfg| assert_raises(ArgumentError) { cfg.otel_content_max_bytes } }
  end

  def test_apply_otel_environment_sets_uppercase_otel_keys
    yaml = <<~YAML
      observability:
        otel:
          env:
            OTEL_SERVICE_NAME: boukensha-test
    YAML
    config_from(yaml) do |cfg|
      with_env("OTEL_SERVICE_NAME" => nil) do
        cfg.apply_otel_environment!
        assert_equal "boukensha-test", ENV["OTEL_SERVICE_NAME"]
      end
    end
  end

  def test_apply_otel_environment_never_overwrites_a_real_env_var
    yaml = <<~YAML
      observability:
        otel:
          env:
            OTEL_SERVICE_NAME: from-yaml
    YAML
    config_from(yaml) do |cfg|
      with_env("OTEL_SERVICE_NAME" => "from-real-env") do
        cfg.apply_otel_environment!
        assert_equal "from-real-env", ENV["OTEL_SERVICE_NAME"]
      end
    end
  end

  def test_apply_otel_environment_rejects_keys_without_otel_prefix
    yaml = <<~YAML
      observability:
        otel:
          env:
            SERVICE_NAME: boukensha-test
    YAML
    config_from(yaml) { |cfg| assert_raises(ArgumentError) { cfg.apply_otel_environment! } }
  end

  def test_apply_otel_environment_rejects_non_scalar_values
    yaml = <<~YAML
      observability:
        otel:
          env:
            OTEL_RESOURCE_ATTRIBUTES:
              - a
              - b
    YAML
    config_from(yaml) { |cfg| assert_raises(ArgumentError) { cfg.apply_otel_environment! } }
  end

  private

  def with_env(pairs)
    old = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

class TestTelemetryBuild < Minitest::Test
  include McpTestHelper

  def test_build_returns_noop_when_disabled
    config_from("") { |cfg| assert_instance_of Boukensha::Telemetry::Noop, Boukensha::Telemetry.build(config: cfg) }
  end

  def test_build_falls_back_to_noop_on_bad_env_mapping_instead_of_raising
    yaml = <<~YAML
      observability:
        otel:
          enabled: true
          env:
            NOT_OTEL_PREFIXED: oops
    YAML
    config_from(yaml) do |cfg|
      warning = StringIO.new
      telemetry = Boukensha::Telemetry.build(config: cfg, warning_io: warning)
      assert_instance_of Boukensha::Telemetry::Noop, telemetry
      assert_match(/OpenTelemetry disabled/, warning.string)
    end
  end
end

class TestTelemetryNoop < Minitest::Test
  def test_in_span_yields_and_returns_the_block_value
    noop = Boukensha::Telemetry::Noop.new
    assert_equal "result", noop.in_span("name") { "result" }
  end

  def test_capture_event_force_flush_and_shutdown_are_harmless
    noop = Boukensha::Telemetry::Noop.new
    assert_nil noop.capture_event({ phase: "response" })
    assert_nil noop.force_flush(timeout: 1)
    assert_nil noop.shutdown(timeout: 1)
  end

  def test_current_ids_is_empty_with_no_span_open
    assert_equal({}, Boukensha::Telemetry::Noop.new.current_ids)
  end
end

# Logger#write_log merges @telemetry.current_ids into every JSONL line —
# this is what lets mud_monitor (Phase 3 of the otel plan) link a
# transcript entry to its trace. Verified against a fake telemetry object
# rather than the real SDK: this is Logger's contract with Telemetry, not
# a test of the SDK itself.
class TestLoggerTraceCorrelation < Minitest::Test
  FakeTelemetry = Struct.new(:ids) do
    def in_span(_name, attributes: {})
      yield
    end

    def capture_event(_event); end
    def current_ids = ids
    def force_flush(timeout: nil); end
    def shutdown(timeout: nil); end
  end

  def test_no_span_open_writes_no_trace_fields
    with_logger(FakeTelemetry.new({})) do |logger, read_lines|
      logger.turn(n: 1)
      event = read_lines.call.last
      refute event.key?("trace_id")
      refute event.key?("span_id")
    end
  end

  def test_open_span_stamps_trace_and_span_id_on_every_line
    ids = { trace_id: "abc123", span_id: "def456" }
    with_logger(FakeTelemetry.new(ids)) do |logger, read_lines|
      logger.turn(n: 1)
      event = read_lines.call.last
      assert_equal "abc123", event["trace_id"]
      assert_equal "def456", event["span_id"]
    end
  end

  private

  def with_logger(telemetry)
    Dir.mktmpdir do |dir|
      logger = Boukensha::Logger.new(dir: dir, telemetry: telemetry)
      read_lines = -> { File.readlines(logger.path).map { |l| JSON.parse(l) } }
      yield logger, read_lines
    ensure
      logger&.close
    end
  end
end
