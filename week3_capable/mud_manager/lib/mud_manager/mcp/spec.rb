require "json"
require_relative "tool_spec"
require_relative "../version"

module MudManager
  module Mcp
    # Renders MudManager::Mcp::ToolSpec as language-neutral JSON — the
    # contract every non-Ruby track can generate typed builders from, or just
    # read to know what's callable. Ruby (ToolSpec) is canonical; this is a
    # rendering of it, not a second source of truth.
    module Spec
      module_function

      def document
        {
          "$schema_note"         => "Generated from MudManager::Mcp::ToolSpec — do not hand-edit.",
          "mud_manager_version"  => MudManager::VERSION,
          "tools"                => ToolSpec::TOOLS.each_with_object({}) do |t, out|
            out[t.name] = {
              "description" => t.description,
              "args" => t.params.each_with_object({}) do |(k, p), h|
                entry = { "type" => p.type }
                entry["values"]   = p.enum if p.enum
                entry["required"] = true if p.required
                h[k.to_s] = entry
              end
            }
          end
        }
      end

      def to_json_pretty
        JSON.pretty_generate(document)
      end
    end
  end
end
