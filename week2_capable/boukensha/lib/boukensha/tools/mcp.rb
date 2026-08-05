require_relative "../mcp/client"

module Boukensha
  module Tools
    # Mcp makes boukensha an MCP host: point it at any MCP server and every
    # tool that server advertises becomes a boukensha tool. It knows nothing
    # about any particular server — `command`/`args`/`env` is the standard
    # stdio transport config, the same triple every other MCP host uses.
    #
    #   Boukensha::Tools::Mcp.register(
    #     registry, command: "mud-manager", args: ["--mcp"],
    #     env: { "MUD_HOST" => "localhost" }, prefix: "tbamud"
    #   )
    #
    # `registry` is anything with the #tool surface — a Registry or the RunDSL
    # yielded to a run/repl block.
    #
    # prefix: scopes the discovered names ("tbamud" => tbamud__look). The
    # prefix is a property of the server entry, supplied by config; this module
    # applies whatever it is given. Names are only prefixed agent-side — the
    # server still sees its own bare name on the wire.
    module Mcp
      SEPARATOR = "__".freeze

      # Two tools claiming one name. Always fatal, even for an optional server:
      # this is a config contradiction, not a server being unreachable, and
      # silently dropping the loser is the expensive failure.
      class CollisionError < ArgumentError; end

      def self.register(registry, command:, args: [], env: {}, prefix: nil, permissions: nil)
        client = Boukensha::Mcp::Client.spawn(command: command, args: args, env: env)
        # Close the server subprocess cleanly when the agent process exits.
        at_exit { client.close rescue nil }
        register_client(registry, client, prefix: prefix, permissions: permissions)
        client
      end

      # Register an already-spawned client's tools. Returns the count
      # advertised by the server (not the count actually let through — see
      # `registry`'s own tool_names for what's really callable, since
      # `permissions:` may filter some out).
      #
      # permissions:, if given, is used for two things `Registry` can't do
      # generically because it needs the tool's MCP-specific inputSchema:
      # boot-time validation of any rule pinning this tool's parameters
      # (`validate_tool!`), and narrowing the advertised enum to the values
      # this task may actually pass (`to_boukensha_params`). Name/value
      # enforcement itself lives in `Registry#tool`/`#dispatch` — this module
      # doesn't gate anything a second time.
      def self.register_client(registry, client, prefix: nil, permissions: nil)
        taken = begin
          registry.respond_to?(:tool_names) ? registry.tool_names.to_a : []
        end

        client.tools.each do |tool|
          remote = tool["name"]
          local  = prefixed(remote, prefix)

          if taken.include?(local)
            raise CollisionError,
                  "boukensha: MCP tool name collision on '#{local}' — a tool by that " \
                  "name is already registered. Give this server a distinct `prefix:` " \
                  "in mcp_servers."
          end

          permissions&.validate_tool!(local, tool["inputSchema"])

          registered_tool = registry.tool(
            local, description: tool["description"].to_s,
            parameters: to_boukensha_params(tool["inputSchema"], permissions: permissions, tool_name: local)
          ) do |**kwargs|
            # Boukensha hands us symbol-keyed kwargs; the server wants strings.
            # Blank/omitted values are normalized server-side.
            result = client.call_tool(remote, kwargs.transform_keys(&:to_s))
            result[:error] ? "error: #{result[:text]}" : result[:text]
          end

          # Only a tool Registry#tool actually let through should count as
          # "taken" — otherwise a name `permissions` rejected here would
          # still block a later, permitted tool of that same name (a
          # spurious collision on a name nothing actually claimed).
          next unless registered_tool

          taken << local
        end
        client.tools.size
      end

      def self.prefixed(name, prefix)
        p = prefix.to_s.strip
        p.empty? ? name.to_s : "#{p}#{SEPARATOR}#{name}"
      end

      # Convert an MCP inputSchema into boukensha's `parameters` shape
      # ({ name => { type:, description: } }). We list every property so the
      # model can supply optional ones too (servers treat blanks as absent).
      #
      # permissions:/tool_name:, if given, narrow an enum param's advertised
      # values to whatever this task's `allow:` rule actually permits, so the
      # model is never offered a value the dispatch guard would reject.
      def self.to_boukensha_params(input_schema, permissions: nil, tool_name: nil)
        props = (input_schema && input_schema["properties"]) || {}
        props.each_with_object({}) do |(pname, schema), out|
          desc = schema["description"].to_s
          enum = schema["enum"]
          if enum && permissions && tool_name
            allowed = permissions.allowed_values(tool_name, pname)
            enum    = enum & allowed if allowed
          end
          desc = "#{desc} (one of: #{enum.join(", ")})".strip if enum
          out[pname.to_sym] = { type: schema["type"] || "string", description: desc }
        end
      end
    end
  end
end
