module Boukensha
  # RunDSL is the object that `self` becomes inside a Boukensha.run block.
  # It exposes only `tool`, keeping the DSL surface intentionally small.
  class RunDSL
    # A block can call `self.hooks = Mud::Hooks.new(...)` to install
    # lifecycle hooks — this is the seam that needs `dispatch` (registry
    # access), which only exists once the block is running, so hooks can't
    # be supplied as a plain run/repl keyword the way logger:/api_key: are.
    # Defaults to the framework no-op so a block that never sets this is
    # unaffected.
    attr_accessor :hooks

    # An open Mud::Memory::Store, set by the entrypoint alongside `hooks`
    # (Phase H). The same instance Mud::Hooks writes through — subagents
    # query the live graph, not a second connection to the same file.
    #
    # Set here rather than passed to .repl for the same reason `hooks` is:
    # the store is created inside the run/repl block, which is the only place
    # that knows whether a `mud` server is configured and whether sqlite3 is
    # even installed.
    attr_accessor :knowledge_store

    def initialize(registry, hooks: Hooks.new)
      @registry        = registry
      @hooks           = hooks
      @knowledge_store = nil
    end

    def tool(name, description:, parameters: {}, &block)
      @registry.tool(name, description: description, parameters: parameters, &block)
    end

    def tool_names
      @registry.tool_names
    end

    # Lets a native tool's own block call another already-registered tool —
    # e.g. RoomSurvey driving poll/inspect/consider/examine itself instead
    # of an LLM deciding each step. Goes through the same Registry#dispatch
    # every MCP-derived tool call does, so it's gated by the same `allow:`
    # rules (Phase A) as everything else — no separate, ungated path.
    def dispatch(name, args = {})
      @registry.dispatch(name, args)
    end
  end
end
