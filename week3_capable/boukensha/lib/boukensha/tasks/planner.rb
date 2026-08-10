require_relative "base"

module Boukensha
  module Tasks
    # The Planner decides what the character is trying to achieve, before the
    # Player is allowed to touch the MUD.
    #
    # It has NO tools, deliberately — not a restricted set, none at all. A
    # planner that can look around will look around, and then it is just a
    # slower Player that happens to write a plan at the end. Keeping it
    # toolless forces the split the orchestrator exists for: the Planner
    # reasons about a goal, the Player finds out what the world actually
    # looks like. Its output is one plan, injected into the Player's system
    # prompt via Context#plan.
    class Planner < Base
      def self.task_name = "planner"

      # A plan is prose, not a transcript — one model call, no loop, and a
      # small output budget so "plan" can't quietly become "essay".
      DEFAULT_MAX_OUTPUT_TOKENS = 600

      def self.max_output_tokens(settings)
        integer_setting(settings, :max_output_tokens, DEFAULT_MAX_OUTPUT_TOKENS)
      end
    end
  end
end
