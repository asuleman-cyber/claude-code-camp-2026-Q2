require_relative "../session"
require_relative "tool_spec"
require_relative "../manager_log"

module MudManager
  module Mcp
    # Executes a single tool call: builds/validates the primitive, ensures the
    # session is connected, sends the command, and returns the MUD's
    # response. Every failure comes back as data ({error: true, text: ...}),
    # never as a raised exception — a tool-level failure must not kill the
    # agent loop on the other end of the pipe.
    class Dispatcher
      def initialize(session_pool, manager_log: MudManager::ManagerLog.from_env)
        @pool = session_pool
        @manager_log = manager_log
      end

      def call(name, arguments)
        tool = ToolSpec.find(name)
        return failure("unknown_tool", "no such tool: #{name}") unless tool

        args = (arguments || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }

        with_manager_log(name: name, args: args, mode: mode_for(tool.dispatch)) do
          case tool.dispatch
          when :raw     then dispatch_raw(args)
          when :poll    then dispatch_poll
          when :status  then dispatch_status
          when :inspect then dispatch_inspect
          else               dispatch_primitive(tool, args)
          end
        end
      rescue ArgumentError, TypeError => e
        failure("argument_error", e.message)
      rescue MudManager::Session::Error => e
        failure(e.class.name.split("::").last.downcase, e.message)
      end

      private

      def mode_for(dispatch)
        dispatch.is_a?(Symbol) ? dispatch.to_s : "command"
      end

      # Records every tool call to the manager log (if enabled) — the "what
      # mud_manager actually executed and returned upward" layer — without
      # touching the dispatch branches above. A no-op wrapper when no log is
      # configured (the common case; off by default).
      def with_manager_log(name:, args:, mode:)
        return yield unless @manager_log

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result  = nil
        error   = nil
        begin
          result = yield
          error  = result[:text] if result[:error]
          result
        rescue StandardError => e
          error = e.message
          raise
        ensure
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          @manager_log.exchange(
            session: "default", mode: mode, tool: name, args: args,
            sent: (mode == "raw" ? args["raw"] : nil),
            received: result && result[:text],
            elapsed_ms: elapsed_ms, error: error
          )
        end
      end

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

      # The composite the agent actually needs on every new room: `look` and
      # `exits` in one round trip instead of two separate tool calls. `look`'s
      # autoexit line only names directions ("[ Exits: n e s w ]"); `exits`
      # names the destination room per direction, which is what makes a room
      # identifiable (bare room names repeat all over the world). Both are
      # cheap on the wire — one extra `read_until_prompt` — so combine them
      # rather than making the agent spend two tool calls to get one room's
      # worth of navigation context.
      def dispatch_inspect
        session = @pool.ensure_connected!
        session.drain
        session.send_command(MudManager::Primitives.look)
        look = session.read_until_prompt

        session.send_command(MudManager::Primitives.info_self("exits"))
        exits = session.read_until_prompt

        success("== look ==\n#{look}\n\n== exits ==\n#{exits}")
      end

      def success(text) = { text: text.to_s, error: false }
      def failure(kind, message) = { text: "#{kind}: #{message}", error: true }
    end
  end
end
