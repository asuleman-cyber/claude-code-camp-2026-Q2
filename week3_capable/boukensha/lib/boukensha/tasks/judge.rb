require_relative "base"

module Boukensha
  module Tasks
    # The Judge looks at what the Player just did and says whether to carry
    # on, re-plan, or stop for a human.
    #
    # It gets tools, but only ones that observe. The reference design this
    # follows calls that "role: inspector"; this codebase has no role concept
    # on its tool specs, and inventing one would mean a parallel gate beside
    # the allowlist Phase A already built and tested. So the read-only surface
    # is expressed as Permissions rules instead — same guarantee, one gate,
    # enforced in Registry#tool/#dispatch like everything else.
    #
    # READ_ONLY_TOOLS is deliberately a code constant rather than a
    # settings.yaml `allow:` block: "the judge cannot move the character" is a
    # correctness property of the orchestrator, not a preference a config edit
    # should be able to switch off by accident.
    class Judge < Base
      def self.task_name = "judge"

      # Bare names, so they match under any MCP prefix (tbamud__look and a
      # second server's look alike) — see Permissions#names_match?.
      #
      # Everything absent from this list is denied by construction, but the
      # ones worth naming explicitly: `move`/`flee`/`set_position` (the Judge
      # must not relocate the character it is assessing), `attack`/
      # `skill_strike` (must not start a fight it was asked to evaluate),
      # every item and shop verb (must not spend or drop anything), and
      # `send_raw` — the arbitrary-command escape hatch, which would make any
      # allowlist above it decorative.
      READ_ONLY_TOOLS = %w[
        look
        examine
        check
        consider
        inspect
        poll
        mud_status
        world_knowledge
      ].freeze

      # A judgement is a paragraph and a verdict, not an investigation. Five
      # iterations is enough to look around and check the character sheet; it
      # is not enough to go wandering, which keeps the checkpoint cheap
      # relative to the Player turn it is checking.
      DEFAULT_MAX_ITERATIONS    = 5
      DEFAULT_MAX_OUTPUT_TOKENS = 500

      VERDICTS = %i[continue replan flag].freeze

      # The Judge is asked to end with a line of exactly this shape.
      VERDICT_PATTERN = /^\s*VERDICT:\s*(continue|replan|flag)\s*$/i.freeze

      def self.max_iterations(settings)
        integer_setting(settings, :max_iterations, DEFAULT_MAX_ITERATIONS)
      end

      def self.max_output_tokens(settings)
        integer_setting(settings, :max_output_tokens, DEFAULT_MAX_OUTPUT_TOKENS)
      end

      def self.permissions
        Permissions.new(READ_ONLY_TOOLS.dup)
      end

      # Extract the verdict from the Judge's reply.
      #
      # Unparseable means :flag, never :continue. A judge whose output we
      # can't read is a judge we have no assurance from — and the failure
      # mode of guessing "continue" is an agent that runs on unsupervised
      # precisely when its supervisor has stopped making sense. Scans from
      # the end so a verdict named while reasoning ("this isn't a replan
      # situation") loses to the real trailing verdict line.
      def self.parse_verdict(text)
        line = text.to_s.lines.reverse.find { |l| VERDICT_PATTERN.match?(l) }
        return :flag unless line

        VERDICT_PATTERN.match(line)[1].downcase.to_sym
      end
    end
  end
end
