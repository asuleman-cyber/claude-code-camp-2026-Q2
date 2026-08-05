require_relative "errors"
require_relative "permissions"

module Boukensha
  class Registry
    # permissions: default is fully permissive (Permissions.permissive), the
    # behavior every existing caller already gets — passing a restrictive
    # Permissions only changes anything for a task whose settings.yaml adds
    # an `allow:` block.
    def initialize(context, permissions: Permissions.permissive)
      @context     = context
      @permissions = permissions
    end

    # Returns the registered Tool, or nil if `name` isn't allowed — the
    # single enforcement point every registration path (MCP discovery via
    # Tools::Mcp, native tools via RunDSL#tool) goes through, so a task's
    # tool surface is one allowlist rather than "the allowlist, plus
    # whatever a caller bolts on unchecked."
    def tool(name, description:, parameters: {}, &block)
      return nil unless @permissions.allow_tool?(name.to_s)

      tool = Tool.new(name.to_s, description, parameters, block)
      @context.register_tool(tool)
      tool
    end

    def tool_names
      @context.tools.keys
    end

    def dispatch(name, args = {})
      tool = @context.tools[name.to_s]
      raise UnknownToolError, "No tool registered as '#{name}'" unless tool
      unless @permissions.call_permitted?(name.to_s, args)
        raise UnauthorizedToolError, "#{name} is not permitted with #{args.inspect}"
      end

      tool.block.call(**args.transform_keys(&:to_sym))
    end
  end
end
