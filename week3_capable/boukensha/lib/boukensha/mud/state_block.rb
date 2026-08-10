module Boukensha
  module Mud
    # Renders the compact block Mud::Hooks#before_model sets on
    # Context#state_block — see basic_memory.md §6.1. This is NOT a tool
    # result: it lives in exactly one copy, re-rendered fresh before every
    # model call, never accumulating and never stale.
    #
    # Deliberately small:
    #   - description only on the first visit (it's static; the agent has
    #     already read it — this is the source plan's own rule, kept).
    #   - `✓`/`?` on each exit marks whether the agent has actually stood in
    #     that destination — the exploration frontier, rendered as one glyph.
    #   - `here:` always comes from the live parse (+ latest poll), never
    #     purely from stored sightings — a stale "cityguard is here" would be
    #     the single worst failure mode this block can have.
    #   - `events` only appears when non-empty.
    module StateBlock
      module_function

      # room:          { name:, description:, visit_count: } or nil (no
      #                position established at all — degrade honestly)
      # exits:         [{ direction:, target_name:, known: }]
      # entities:      [{ text:, kind:, threat: }] — live-parsed, this visit
      # events:        String or nil
      # player_state:  { hp:, max_hp:, mana:, move:, level:, gold:, position: } or nil
      # uncertain:     true when room identity could not be resolved to one
      #                confident row (ambiguous fingerprint)
      def render(room:, exits: [], entities: [], events: nil, player_state: nil, uncertain: false)
        return "[here] unknown — no room established yet" if room.nil?

        lines = [here_line(room, uncertain: uncertain)]
        lines << "exits: #{format_exits(exits)}" if exits.any?
        lines << "description: #{room[:description]}" if room[:visit_count].to_i <= 1 && !room[:description].to_s.empty?
        lines << "here: #{format_entities(entities)}" if entities.any?
        lines << "events: #{events}" if events && !events.to_s.strip.empty?
        lines << "you: #{format_player(player_state)}" if player_state

        lines.join("\n")
      end

      def here_line(room, uncertain:)
        visits = room[:visit_count].to_i
        suffix = uncertain ? " (uncertain)" : (visits > 1 ? "  (visit #{visits})" : "")
        "[here] #{room[:name]}#{suffix}"
      end

      def format_exits(exits)
        exits.map { |e| "#{e[:direction]}→#{e[:target_name] || "?"} #{e[:known] ? "✓" : "?"}" }.join(" | ")
      end

      def format_entities(entities)
        entities.map do |e|
          detail = e[:threat] ? " — #{e[:threat]}" : ""
          "#{e[:text]} (#{e[:kind]}#{detail})"
        end.join(" | ")
      end

      def format_player(p)
        parts = []
        if p[:hp]
          hp = p[:max_hp] ? "#{p[:hp]}/#{p[:max_hp]}hp" : "#{p[:hp]}hp"
          parts << hp
        end
        parts << "#{p[:mana]}mana" if p[:mana]
        parts << "#{p[:move]}mv" if p[:move]
        parts << "lvl #{p[:level]}" if p[:level]
        parts << "#{p[:gold]} gold" if p[:gold]
        parts << p[:position] if p[:position]
        parts.join(" · ")
      end
    end
  end
end
