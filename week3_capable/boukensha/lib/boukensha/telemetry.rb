require_relative "telemetry/noop"

module Boukensha
  module Telemetry
    # Returns a real OpenTelemetry-backed telemetry object when
    # config.otel_enabled? is true, a Noop otherwise. Any failure to load or
    # configure the SDK (gem not installed, bad settings.yaml, exporter
    # unreachable) degrades to Noop rather than taking a run down — the same
    # "optional at runtime" posture this gem already takes with the TUI (see
    # boukensha.gemspec's charm comment).
    def self.build(config:, warning_io: $stderr)
      return Noop.new unless config.otel_enabled?

      begin
        config.apply_otel_environment!
        require_relative "telemetry/open_telemetry"
        OpenTelemetry.new(
          capture_content: config.otel_capture_content?,
          content_max_bytes: config.otel_content_max_bytes,
          warning_io: warning_io
        )
      rescue LoadError, StandardError => e
        ErrorLog.from_env&.record(e, context: "otel")
        warning_io.puts("boukensha: OpenTelemetry disabled: #{e.class}: #{e.message}")
        Noop.new
      end
    end
  end
end
