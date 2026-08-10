module Boukensha
  module Mud
    # Pure text -> Hash, no I/O — same shape as Mud::RoomParser. Three entry
    # points, one per command whose output docs/plans/player_map_plan.md
    # Part 1 wants captured: parse_score, parse_inventory, parse_equipment.
    #
    # Built and tested against boukensha/test/fixtures/player/*.txt — real
    # captures from this MUD, not the wording assumed by the plan doc, per
    # the plan's own Step 1 rule ("assume nothing about score/inventory/
    # equipment wording until this step has actually run").
    #
    # Two things the fixtures caught that the plan's schema comment didn't
    # anticipate:
    #
    #   1. Equipment slots are NOT one-item-per-slot. Two finger slots, two
    #      neck slots, and two wrist slots all print the same bracketed
    #      label twice ("<worn on finger>" appears once per ring). Store's
    #      player_equipment.slot is UNIQUE (plan §2), so parse_equipment
    #      disambiguates repeats by suffixing " (2)", " (3)", ... onto the
    #      slot label rather than dropping the second item silently.
    #   2. The captured inventory was empty ("You are carrying: / Nothing.")
    #      — there is no live-verified example of a multi-item inventory
    #      line (whether a stacked count prints as a "(4)" suffix, an "(x4)"
    #      prefix, or not at all). parse_inventory handles the empty case
    #      exactly as captured and the general case on a best-effort basis
    #      (a trailing "(N)" is read as quantity); treat that path as
    #      unverified until a populated inventory has actually been seen.
    module PlayerParser
      ANSI_RE = /\e\[[0-9;]*m/

      AGE_RE            = /You are (\d+) years old/
      VITALS_RE         = /You have (\d+)\((\d+)\) hit, (\d+)\((\d+)\) mana and (\d+)\((\d+)\) movement points/
      AC_ALIGN_RE       = /Your armor class is ([^,\s]+), and your alignment is (-?\d+)/
      EXP_GOLD_RE       = /You have (\d+) exp, (\d+) gold coins?, and (\d+) questpoints/
      EXP_NEXT_RE       = /You need (\d+) exp to reach your next level/
      QUEST_EARNED_RE   = /You have earned (\d+) quest points/
      LEVEL_RE          = /\(level (\d+)\)/
      POSITION_WORDS    = %w[standing sitting resting sleeping fighting].freeze
      POSITION_LINE_RE  = /\AYou are (\w+)\.?\z/

      COUNT_SUFFIX_RE = /\A(.+?)\s*\((\d+)\)\z/
      EQUIP_LINE_RE   = /\A<([^>]+)>\s+(.+?)\s*\z/

      ITEM_STOPWORDS = %w[a an the of pair set].freeze

      module_function

      # "You are 18 years old. / ... / This ranks you as X (level 1)." ->
      # { age:, hp:, max_hp:, mana:, max_mana:, move:, max_move:,
      #   armor_class:, alignment:, exp:, gold:, quest_points:,
      #   exp_to_next_level:, level:, position: }. Any field the text
      # doesn't contain (e.g. exp_to_next_level at max level, never seen
      # live) comes back nil rather than guessed.
      def parse_score(text)
        plain = strip_ansi(text)

        fields = { age: nil, hp: nil, max_hp: nil, mana: nil, max_mana: nil, move: nil, max_move: nil,
                   armor_class: nil, alignment: nil, exp: nil, gold: nil, quest_points: nil,
                   exp_to_next_level: nil, level: nil, position: nil }

        if (m = AGE_RE.match(plain))
          fields[:age] = m[1].to_i
        end

        if (m = VITALS_RE.match(plain))
          fields[:hp], fields[:max_hp], fields[:mana], fields[:max_mana], fields[:move], fields[:max_move] =
            m.captures.map(&:to_i)
        end

        if (m = AC_ALIGN_RE.match(plain))
          fields[:armor_class] = m[1]
          fields[:alignment]   = m[2].to_i
        end

        if (m = EXP_GOLD_RE.match(plain))
          fields[:exp]  = m[1].to_i
          fields[:gold] = m[2].to_i
          # Overwritten below by QUEST_EARNED_RE if present — that line's
          # wording ("quest points") matches the schema column name more
          # directly than this line's "questpoints", so it wins when both
          # are present (see class doc — the two have only ever been seen
          # equal, at 0, so this is a naming preference, not a verified
          # distinction).
          fields[:quest_points] = m[3].to_i
        end

        if (m = EXP_NEXT_RE.match(plain))
          fields[:exp_to_next_level] = m[1].to_i
        end

        if (m = QUEST_EARNED_RE.match(plain))
          fields[:quest_points] = m[1].to_i
        end

        if (m = LEVEL_RE.match(plain))
          fields[:level] = m[1].to_i
        end

        plain.split("\r\n").each do |line|
          m = POSITION_LINE_RE.match(line.strip)
          next unless m && POSITION_WORDS.include?(m[1])

          fields[:position] = m[1]
          break
        end

        fields
      end

      # "You are carrying:\r\n  Nothing.\r\n..." -> []. Otherwise one Hash
      # per line: { descr:, keyword:, quantity: }. See class doc — the
      # quantity-suffix handling is best-effort, unverified against a real
      # populated inventory.
      def parse_inventory(text)
        parse_item_list(text, header: "You are carrying:")
      end

      def parse_item_list(text, header:)
        lines = strip_ansi(text).split("\r\n").map(&:strip)
        start = lines.index { |l| l == header }
        return [] unless start

        lines[(start + 1)..].each_with_object([]) do |line, out|
          break out if line.empty? || line.match?(/\d+H\s+\d+M\s+\d+V/)
          next if line == "Nothing."

          descr, quantity = if (m = COUNT_SUFFIX_RE.match(line))
                               [m[1], m[2].to_i]
                             else
                               [line, 1]
                             end
          out << { descr: descr, keyword: guess_item_keyword(descr), quantity: quantity }
        end
      end
      private_class_method :parse_item_list

      # "You are using:\r\n<worn on finger>     a leather ring\r\n..." ->
      # one Hash per line: { slot:, descr:, keyword: }. A slot label that
      # repeats (two finger/neck/wrist slots) is disambiguated as
      # " (2)", " (3)", ... — see class doc point 1.
      def parse_equipment(text)
        lines = strip_ansi(text).split("\r\n").map(&:strip)
        start = lines.index { |l| l == "You are using:" }
        return [] unless start

        seen_slots = Hash.new(0)

        lines[(start + 1)..].each_with_object([]) do |line, out|
          m = EQUIP_LINE_RE.match(line)
          break out unless m

          slot_label = m[1].strip
          descr      = m[2]

          seen_slots[slot_label] += 1
          occurrence = seen_slots[slot_label]
          slot = occurrence == 1 ? slot_label : "#{slot_label} (#{occurrence})"

          out << { slot: slot, descr: descr, keyword: guess_item_keyword(descr) }
        end
      end

      # "a pair of bronze leggings" -> "leggings"; "a leather ring" ->
      # "ring". Same "drop articles, take the last remaining word" heuristic
      # as RoomParser.guess_keyword, plus a couple of item-list-only
      # stopwords ("pair", "set") that don't apply to room prose.
      def guess_item_keyword(text)
        words = text.to_s.downcase.gsub(/[^a-z\s]/, "").split
        candidates = words.reject { |w| ITEM_STOPWORDS.include?(w) }
        candidates.last
      end

      def strip_ansi(text)
        text.to_s.gsub(ANSI_RE, "")
      end
    end
  end
end
