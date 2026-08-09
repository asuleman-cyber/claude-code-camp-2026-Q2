module Boukensha
  module Telemetry
    # Null object so Logger and Agent never have to branch on whether OTel
    # is enabled — there's always a @telemetry to call, it just does
    # nothing when observability.otel isn't turned on.
    class Noop
      def in_span(_name, attributes: {})
        yield
      end

      def capture_event(_event); end

      def current_ids
        {}
      end

      def force_flush(timeout: nil); end

      def shutdown(timeout: nil); end
    end
  end
end
