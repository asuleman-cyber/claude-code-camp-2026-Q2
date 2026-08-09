require "opentelemetry-api"
require "opentelemetry-sdk"
require "opentelemetry/exporter/otlp"
require "json"

module Boukensha
  module Telemetry
    # One OTel span per top-level turn (Agent#run wraps its body in
    # Logger#in_span), exported over OTLP. Every event Logger#write_log
    # already produces becomes a span event on whatever span is current —
    # so this adds no second code path to keep in sync with the JSONL log,
    # it just mirrors what's already being written.
    #
    # Pinned to OpenTelemetry GenAI semantic conventions 1.37.0 — attribute
    # changes here need an explicit compatibility review even when SDK
    # dependencies are upgraded.
    class OpenTelemetry
      SEMANTIC_CONVENTIONS = "OpenTelemetry GenAI semantic conventions 1.37.0".freeze

      # Logger#write_log phases that can carry real content, gated by
      # capture_content. Everything else (turn, iteration, limit_reached,
      # turn_end, compaction, session_start) only ever contributes
      # metadata — there's nothing content-shaped to redact or gate there.
      CONTENT_PHASES = %w[prompt response tool_call tool_result plan].freeze

      def initialize(capture_content: false, content_max_bytes: 4096, warning_io: $stderr)
        @capture_content   = capture_content
        @content_max_bytes = content_max_bytes
        @warning_io        = warning_io
        configure_once
        @tracer = ::OpenTelemetry.tracer_provider.tracer("boukensha", Boukensha::VERSION)
      end

      # Opens one span, makes it current for the duration of the block, and
      # finishes it on the way out. An exception is recorded on the span
      # before it re-propagates — this never swallows an error, only
      # annotates it.
      def in_span(name, attributes: {})
        span    = @tracer.start_span(name.to_s, attributes: clean(attributes))
        context = ::OpenTelemetry::Trace.context_with_span(span)
        ::OpenTelemetry::Context.with_current(context) { yield }
      rescue StandardError => e
        span&.record_exception(e)
        span&.status = ::OpenTelemetry::Trace::Status.error(e.message)
        raise
      ensure
        span&.finish
      end

      # Called from Logger#write_log for every event it writes. A no-op
      # when no span is open (e.g. Logger's session_start, written before
      # the first turn's span exists).
      def capture_event(event)
        span = ::OpenTelemetry::Trace.current_span
        return unless span.context.valid?

        phase = (event[:phase] || event["phase"]).to_s

        if phase == "reasoning"
          span.add_event("boukensha.reasoning", attributes: { "boukensha.reasoning.present" => true })
          return
        end

        attributes = { "boukensha.session_id" => event[:session_id] || event["session_id"] }.compact
        if @capture_content && CONTENT_PHASES.include?(phase)
          json      = JSON.generate(redact(event))
          truncated = json.bytesize > @content_max_bytes
          json      = json.byteslice(0, @content_max_bytes).scrub if truncated
          attributes["boukensha.content"]           = json
          attributes["boukensha.content.truncated"] = truncated
        end
        span.add_event("boukensha.#{phase}", attributes: attributes)
      rescue StandardError => e
        warn_once(e)
      end

      # Read by Logger#write_log and merged into the JSONL line so
      # mud_monitor can link a transcript entry straight to its trace —
      # {} whenever no span is open (capture_event already no-ops the same
      # way), so callers never need to check first.
      def current_ids
        context = ::OpenTelemetry::Trace.current_span.context
        return {} unless context.valid?

        { trace_id: context.hex_trace_id, span_id: context.hex_span_id }
      end

      def force_flush(timeout: nil)
        ::OpenTelemetry.tracer_provider.force_flush(timeout: timeout)
      rescue StandardError => e
        warn_once(e)
        false
      end

      def shutdown(timeout: nil)
        ::OpenTelemetry.tracer_provider.shutdown(timeout: timeout)
      rescue StandardError => e
        warn_once(e)
        false
      end

      private

      def configure_once
        return if self.class.instance_variable_get(:@configured)

        ::OpenTelemetry::SDK.configure do |config|
          config.service_name = ENV.fetch("OTEL_SERVICE_NAME", "boukensha")
        end
        self.class.instance_variable_set(:@configured, true)
      end

      def clean(attributes)
        attributes.compact.transform_keys(&:to_s).select do |_key, value|
          value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
        end
      end

      SECRET_KEY   = /(authorization|api[_-]?key|token|password|secret|credential)/i
      SECRET_VALUE = /(Bearer\s+)[^\s]+|\bsk-[A-Za-z0-9_-]{8,}/i

      # Applied to event content before it ever touches a span.
      def redact(value, key = nil)
        return "[REDACTED]" if key&.match?(SECRET_KEY)

        case value
        when Hash
          value.each_with_object({}) { |(child_key, child), out| out[child_key] = redact(child, child_key.to_s) }
        when Array
          value.map { |child| redact(child) }
        when String
          value.gsub(SECRET_VALUE) { |match| match.start_with?("Bearer ") ? "Bearer [REDACTED]" : "[REDACTED]" }
        else
          value
        end
      end

      def warn_once(error)
        return if @warned

        @warned = true
        @warning_io.puts("boukensha: OpenTelemetry export failed: #{error.class}: #{error.message}")
      end
    end
  end
end
