require_relative "base"

module Boukensha
  module Tasks
    # The Navigator answers "how do I get there?" — and only that.
    #
    # ## Why an LLM at all, when Phase H's BFS is exact
    #
    # `world_knowledge(kind: route)` already returns the shortest walked path
    # deterministically, and this project's default is deterministic-over-LLM
    # (Phase C deleted an LLM room-inspector loop in favour of a parser for
    # exactly that reason). So the Navigator has to earn its call, and it only
    # does in the cases BFS cannot answer:
    #
    #   - **A name that isn't a room name.** "the temple", "a shop", "back to
    #     where the guard was". BFS needs a row in `rooms`; a caller has prose.
    #   - **No route exists.** The useful answer is then not "no" but "the
    #     nearest frontier pointing that way is west from Market Square" —
    #     which means reading the map, not querying one path.
    #   - **Ambiguity.** Several rooms match; picking needs judgement about
    #     which one the caller meant.
    #
    # When the destination is an exact known room name and a route exists, the
    # Navigator is a more expensive BFS. That is the honest trade, and it is
    # why `consult_navigator`'s description tells callers to use it for
    # *unclear* destinations — a caller that knows the room name should call
    # `world_knowledge` directly, and the Judge (which has both) is told so.
    #
    # ## What it cannot do
    #
    # It never moves the character. Not by convention — by allowlist: it gets
    # `world_knowledge` and nothing else, so `move`, `look`, and every other
    # MUD tool are filtered out at registration by Phase A's Permissions and
    # are not merely unused but absent. It answers whether a path exists; the
    # caller walks it.
    class Navigator < Base
      def self.task_name = "navigator"

      # The single tool. Bare name, so it matches under any MCP prefix —
      # though world_knowledge is native and unprefixed today.
      ALLOWED_TOOLS = %w[world_knowledge].freeze

      # Four iterations is enough to look up two rooms and ask for a route
      # between them. It is not enough to tour the map — which matters,
      # because this runs *inside* another agent's turn and its cost lands on
      # that turn's budget.
      DEFAULT_MAX_ITERATIONS    = 4
      DEFAULT_MAX_OUTPUT_TOKENS = 350

      def self.max_iterations(settings)
        integer_setting(settings, :max_iterations, DEFAULT_MAX_ITERATIONS)
      end

      def self.max_output_tokens(settings)
        integer_setting(settings, :max_output_tokens, DEFAULT_MAX_OUTPUT_TOKENS)
      end

      def self.permissions
        Permissions.new(ALLOWED_TOOLS.dup)
      end
    end
  end
end
