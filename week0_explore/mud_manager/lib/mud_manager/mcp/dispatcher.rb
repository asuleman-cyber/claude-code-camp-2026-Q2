require_relative "../session"
require_relative "tool_spec"

module MudManager
  module Mcp
    # Executes a single tool call: builds/validates the primitive, ensures the
    # session is connected, sends the command, and returns the MUD's
    # response. Every failure comes back as data ({error: true, text: ...}),
    # never as a raised exception — a tool-level failure must not kill the
    # agent loop on the other end of the pipe.
    class Dispatcher
      def initialize(session_pool)
        @pool = session_pool
      end

      def call(name, arguments)
        tool = ToolSpec.find(name)
        return failure("unknown_tool", "no such tool: #{name}") unless tool

        args = (arguments || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }

        case tool.dispatch
        when :raw    then dispatch_raw(args)
        when :poll   then dispatch_poll
        when :status then dispatch_status
        else              dispatch_primitive(tool, args)
        end
      rescue ArgumentError, TypeError => e
        failure("argument_error", e.message)
      rescue MudManager::Session::Error => e
        failure(e.class.name.split("::").last.downcase, e.message)
      end

      private

      # Build the command (may raise ArgumentError) BEFORE touching the
      # session, so an invalid call never pays for a connect+login.
      def dispatch_primitive(tool, args)
        command = tool.dispatch.call(args)
        session = @pool.ensure_connected!
        session.drain
        session.send_command(command)
        success(session.read_until_prompt)
      end

      def dispatch_raw(args)
        raise ArgumentError, "raw is required" if ToolSpec.present(args["raw"]).nil?
        session = @pool.ensure_connected!
        session.drain
        session.send_command(args["raw"])
        success(session.read_until_prompt)
      end

      def dispatch_poll
        session = @pool.connected_session
        success(session ? session.drain : "")
      end

      def dispatch_status
        success(@pool.status_text)
      end

      def success(text) = { text: text.to_s, error: false }
      def failure(kind, message) = { text: "#{kind}: #{message}", error: true }
    end
  end
end
