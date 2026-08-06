module Boukensha
  # Five lifecycle seams in the agent loop, exposed as a null object so every
  # existing caller/test is unaffected until something subclasses this.
  # Per docs/plans/week_2/lifecycle_hooks.md + basic_memory.md §5.2:
  #
  #   before_turn   — once per user turn
  #   before_model  — once per model iteration (fires before EVERY call, not
  #                   just the first — the agent moves *inside* its own loop)
  #   before_tools  — once per tool-use batch, before the first dispatch —
  #                   the only moment async MUD output between iterations is
  #                   still recoverable (see Mud::Hooks#before_tools)
  #   after_tool    — once per tool call, after Registry#dispatch. Returning
  #                   non-nil REPLACES what the model sees in its context;
  #                   the logger still records the tool's real output either
  #                   way, so the session log/mud_monitor stay a faithful
  #                   record even when the model's copy is trimmed.
  #   after_turn    — once, immediately before the agent returns its response
  #
  # A hook body must never raise into the agent loop — a broken hook should
  # degrade the agent back to "no memory," not crash the turn. Subclasses are
  # expected to wrap their own bodies in rescue; this base class enforces
  # nothing (it has nothing to protect against — a no-op can't raise).
  class Hooks
    def before_turn(context:) = nil
    def before_model(context:) = nil
    def before_tools(calls:, context:) = nil
    def after_tool(name:, args:, result:, context:) = nil
    def after_turn(context:, text:) = nil
  end
end
