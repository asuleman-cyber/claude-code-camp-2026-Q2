module Boukensha
  # Permissions is a pure allowlist, default-deny gate over tool calls.
  #
  # Built from a task's `allow:` block in settings.yaml — an array of rule
  # strings, one tool per rule:
  #
  #   tasks:
  #     player:
  #       allow:
  #         - move
  #         - attack
  #         - check(kind: score|inventory|equipment)
  #         - inspect
  #
  # `Permissions.permissive` (no `allow:` block at all — the default for any
  # task that doesn't opt in) allows every tool name and every argument
  # value. Nothing that doesn't add `allow:` changes behavior. The instant a
  # task's settings.yaml gains an `allow:` block, that task becomes
  # default-deny: only tools a rule names may be registered, and only with
  # argument values a rule permits.
  #
  # Rule grammar (one string per rule):
  #
  #   Rule    ::= ToolName [ "(" Arg { "," Arg } ")" ]
  #   Arg     ::= Param ":" Pattern
  #   Pattern ::= "*" | Value { "|" Value }        ; "*" = any value
  #
  # Tool names are bare ("check") or prefixed ("tbamud__check"). A bare rule
  # matches a tool under any MCP prefix, so `allow: [check]` covers
  # `tbamud__check` (and any other server's `check`) without knowing the
  # prefix in advance. A rule that already includes "__" matches only that
  # exact name. A parameter a rule doesn't mention is unconstrained.
  class Permissions
    class InvalidRuleError < ArgumentError; end

    Rule = Struct.new(:tool, :params) # params: { "kind" => nil-or-Array<String> }

    RULE_PATTERN = /\A([A-Za-z0-9_]+)(?:\((.*)\))?\z/.freeze

    def self.permissive
      new(nil)
    end

    # rules: nil (no `allow:` block — permissive), or the Array of rule
    # strings from `allow:`.
    def initialize(rules)
      @permissive = rules.nil?
      @rules      = (rules || []).map { |r| parse(r) }
    end

    def permissive?
      @permissive
    end

    # Name-level gate: may this task's registry even register/see `name`?
    def allow_tool?(name)
      return true if @permissive

      !!matching_rule(name.to_s)
    end

    # Value-level gate: may `name` be dispatched with these `args`?
    def call_permitted?(name, args)
      return true if @permissive

      rule = matching_rule(name.to_s)
      return false unless rule

      args.all? do |param, value|
        allowed = rule.params[param.to_s]
        allowed.nil? || allowed.include?(value.to_s)
      end
    end

    # Allowed values for `name`'s `param`, or nil if unconstrained (no rule,
    # no matching tool, or the param is a wildcard/unmentioned). Used to
    # narrow an advertised MCP enum to what this task may actually pass.
    def allowed_values(name, param)
      return nil if @permissive

      rule = matching_rule(name.to_s)
      rule && rule.params[param.to_s]
    end

    # Boot-time check: does every rule's pinned parameter exist on the real
    # tool, and is every pinned value inside that parameter's real enum (when
    # the schema declares one)? Called as each tool is registered, with that
    # tool's MCP inputSchema. No-op for tools no rule names, and for native
    # tools (input_schema nil) — see docs on native tool parameters.
    def validate_tool!(name, input_schema)
      return if @permissive

      rule = matching_rule(name.to_s)
      return unless rule
      return if rule.params.empty?

      props = (input_schema && input_schema["properties"]) || {}
      rule.params.each do |param, values|
        schema = props[param]
        raise InvalidRuleError, "'#{rule.tool}' has no parameter '#{param}'" unless schema
        next if values.nil? # "*" or unmentioned — nothing to check

        enum = schema["enum"]
        unless enum
          raise InvalidRuleError, "parameter '#{param}' of '#{rule.tool}' is not constrainable (no enum)"
        end

        values.each do |v|
          next if enum.include?(v)

          raise InvalidRuleError, "#{v} is not a valid #{param} (one of: #{enum.join(", ")})"
        end
      end
    end

    # Boot-time check: does every rule reference a tool that actually got
    # registered? Call once, after ALL registration (MCP + native) completes
    # — a rule for a not-yet-registered native tool would otherwise look like
    # a typo.
    def validate_referenced!(registered_names)
      return if @permissive

      known = registered_names.to_a
      @rules.each do |rule|
        next if known.any? { |n| names_match?(n.to_s, rule.tool) }

        raise InvalidRuleError, "permission rule references unknown tool '#{rule.tool}'"
      end
    end

    private

    def matching_rule(name)
      @rules.find { |rule| names_match?(name, rule.tool) }
    end

    # A bare rule ("check") matches an exact bare tool of the same name, or
    # any prefixed tool with that base name ("tbamud__check"). A rule that
    # already contains "__" matches only that exact name.
    def names_match?(tool_name, rule_tool)
      return true if tool_name == rule_tool

      !rule_tool.include?("__") && tool_name.end_with?("__#{rule_tool}")
    end

    def parse(raw)
      m = RULE_PATTERN.match(raw.to_s.strip)
      raise InvalidRuleError, "invalid permission rule: #{raw.inspect}" unless m

      tool   = m[1]
      params = {}

      if m[2]
        m[2].split(",").each do |arg|
          param, pattern = arg.split(":", 2)
          raise InvalidRuleError, "invalid permission rule: #{raw.inspect}" unless param && pattern

          param   = param.strip
          pattern = pattern.strip
          params[param] = pattern == "*" ? nil : pattern.split("|").map(&:strip)
        end
      end

      Rule.new(tool, params)
    end
  end
end
