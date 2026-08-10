require_relative "base"

module Boukensha
  module Tasks
    # The Chronicler turns what just happened into what the character will
    # remember. It reads the session and rewrites the prose digest; nothing
    # else writes that file.
    #
    # **Zero tools, and that is the design, not an oversight.** A Chronicler
    # with tools would go and check the world before writing memory — which
    # sounds diligent and is exactly wrong. Tools and the world map are not
    # memory: `world_knowledge` already answers "what is there?", live and
    # accurately, and duplicating it into a prose digest produces a second,
    # staler copy of facts that are already free. What belongs here is the
    # part no tool can answer — what was tried, what it cost, what to do
    # differently. Denying tools is how that stays true.
    #
    # It is also why the Chronicler is given a transcript rather than a
    # database: it is summarising an experience, not querying a state.
    class Chronicler < Base
      def self.task_name = "chronicler"

      # One call, and a digest is a page. This is the cheapest role in the
      # system and should stay that way — it runs at session boundaries,
      # where a slow or expensive step is most likely to be interrupted.
      DEFAULT_MAX_OUTPUT_TOKENS = 800

      def self.max_output_tokens(settings)
        integer_setting(settings, :max_output_tokens, DEFAULT_MAX_OUTPUT_TOKENS)
      end
    end
  end
end
