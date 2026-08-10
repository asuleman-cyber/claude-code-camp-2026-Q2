require "json"
require_relative "session_pool"
require_relative "dispatcher"
require_relative "tool_spec"
require_relative "../version"

module MudManager
  module Mcp
    # Speaks MCP (JSON-RPC 2.0) over stdio: one JSON object per line in, one
    # JSON object per line out. Session lifecycle is entirely hidden behind
    # the tool boundary — see SessionPool. The LLM only ever sees gameplay
    # tools plus send_raw/poll/mud_status.
    class Server
      PROTOCOL_VERSION = "2025-06-18".freeze

      def initialize(input: $stdin, output: $stdout, session_pool: SessionPool.new)
        @input      = input
        @output     = output
        @dispatcher = Dispatcher.new(session_pool)
      end

      def run
        @input.each_line do |line|
          line = line.strip
          next if line.empty?
          handle(line)
        end
      end

      private

      def handle(line)
        msg    = JSON.parse(line)
        id     = msg["id"]
        method = msg["method"]
        params = msg["params"] || {}

        result =
          case method
          when "initialize"                then initialize_result
          when "notifications/initialized" then nil
          when "tools/list"                then { "tools" => ToolSpec.to_mcp_tools }
          when "tools/call"                then tools_call(params)
          when "ping"                      then {}
          else
            return respond_error(id, -32601, "method not found: #{method}") if id
            return
          end

        respond(id, result) if id
      rescue JSON::ParserError => e
        warn "[mud-manager] bad JSON-RPC line: #{e.message}"
      end

      def initialize_result
        {
          "protocolVersion" => PROTOCOL_VERSION,
          "capabilities"    => { "tools" => {} },
          "serverInfo"      => { "name" => "mud-manager", "version" => MudManager::VERSION }
        }
      end

      def tools_call(params)
        outcome = @dispatcher.call(params["name"], params["arguments"] || {})
        {
          "content" => [{ "type" => "text", "text" => outcome[:text] }],
          "isError" => outcome[:error]
        }
      end

      def respond(id, result)
        write({ "jsonrpc" => "2.0", "id" => id, "result" => result })
      end

      def respond_error(id, code, message)
        write({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } })
      end

      def write(obj)
        @output.puts(JSON.generate(obj))
        @output.flush
      end
    end
  end
end
