module Boukensha
  module Mud
    # Pure text → Hash. No I/O, no network, no LLM — every field here is
    # mechanically derivable from the MUD's own output, per
    # docs/plans/week_2/scripted_room_survey.md §3.2/§3.3 (colleague repo).
    #
    # Was Boukensha::Tools::RoomParser (Phase C); moved under Mud:: in
    # Phase D per docs/plans/week_2/basic_memory.md §9 — everything that
    # knows what a MUD is belongs in one explicitly-named namespace, not
    # spread through `tools/` (which now holds only mcp.rb, matching
    # boukensha's own "ships no tools of its own" claim).
    #
    # Reused on TWO kinds of text: a full `inspect` composite (look+exits,
    # Phase A) when surveying a room, and a bare `move` result (no "==
    # exits ==" section — split_sections falls back to treating the whole
    # string as the look portion). Both shapes parse through the same code
    # path; a move result just yields an empty exit_targets.
    #
    # Ground objects print in green (`CCGRN`, `\e[0;32m`), mobs and the room
    # name itself print in yellow (`CCYEL`, `\e[0;33m`) — verified against
    # tbaMUD source AND this MUD's own live output (Phase C); position
    # (first line vs. after the exits marker) disambiguates the room name
    # from a mob.
    #
    # Deliberately does NOT attempt `look_candidates` — out of scope, see
    # docs/plans/week2_catchup_plan.md Phase C.
    module RoomParser
      YELLOW = "\e[0;33m"
      GREEN  = "\e[0;32m"
      CYAN   = "\e[0;36m"

      ANSI_RE         = /\e\[[0-9;]*m/
      EXITS_MARKER_RE = /\[\s*Exits:\s*([^\]]*)\]/
      VITALS_RE       = /(\d+)H\s+(\d+)M\s+(\d+)V/
      EXIT_LINE_RE    = /\A(\w+)\s*-\s*(.+?)\s*\z/

      DIRECTION_WORDS = {
        "n" => "north", "e" => "east", "s" => "south", "w" => "west", "u" => "up", "d" => "down"
      }.freeze

      module_function

      # inspect_text: either the `inspect` MCP tool's composite
      # ("== look ==\n...\n\n== exits ==\n...") or a bare move/look result.
      def parse(inspect_text)
        look_text, exits_text = split_sections(inspect_text.to_s)

        name              = nil
        description_lines = []
        entities          = []
        vitals            = nil
        exit_letters      = []
        past_exits_marker = false

        look_text.split("\r\n").each do |raw_line|
          plain = strip_ansi(raw_line).strip

          if name.nil?
            next if plain.empty?

            name = plain
            next
          end

          if !past_exits_marker && (m = EXITS_MARKER_RE.match(plain))
            past_exits_marker = true
            exit_letters = m[1].to_s.split
            next
          end

          if (m = VITALS_RE.match(plain))
            vitals = { hp: m[1].to_i, mana: m[2].to_i, move: m[3].to_i }
            next
          end

          next if plain.empty?

          if past_exits_marker
            entities << classify_entity(raw_line, plain)
          else
            description_lines << plain
          end
        end

        exit_targets = parse_exit_targets(exits_text)

        {
          name: name,
          description: description_lines.join(" ").gsub(/\s+/, " ").strip,
          vitals: vitals,
          mobs: entities.select { |e| e[:type] == :mob },
          objects: entities.select { |e| e[:type] == :object },
          exit_targets: exit_targets,
          # The direction list for fingerprinting (Fingerprint.weak): prefer
          # exit_targets' keys (full words, from a real survey) since they're
          # more precise; fall back to the bare `[ Exits: e w ]` letters
          # (expanded to full words) available even from a move result, at
          # zero extra cost.
          exit_directions: exit_targets.any? ? exit_targets.keys : exit_letters.map { |l| DIRECTION_WORDS[l] || l }
        }
      end

      # True if `text` confidently looks like a successful room
      # arrival/look — a room name, an exits marker, AND a vitals line all
      # present. Used to gate the after_tool move-substitution: substitute
      # only on this whitelist, never on a guess (basic_memory.md §6.2 —
      # "a wrongly swallowed failure costs a stuck agent").
      def room_shape?(text)
        plain = strip_ansi(text.to_s)
        plain.match?(EXITS_MARKER_RE) && plain.match?(VITALS_RE) && !first_nonblank_line(plain).to_s.strip.empty?
      end

      def first_nonblank_line(text)
        text.split("\r\n").map { |l| strip_ansi(l).strip }.find { |l| !l.empty? }
      end

      # "== look ==\n...\n\n== exits ==\n..." -> ["...", "..."]. Tolerates
      # either section being absent (returns "" for it) so a caller that
      # only has one half still gets a sane parse.
      def split_sections(text)
        look_match  = text.match(/== look ==\n(.*?)(?:\n\n== exits ==\n|\z)/m)
        exits_match = text.match(/== exits ==\n(.*)\z/m)
        [look_match ? look_match[1] : text, exits_match ? exits_match[1] : ""]
      end

      # "Obvious exits:\r\nnorth - By The Temple Altar\r\n..." ->
      # { "north" => "By The Temple Altar", ... }. A destination the server
      # can't identify ("Too dark to tell.") is kept verbatim — it is still
      # useful (there IS an exit that way) even though it can't become a
      # room-identity key.
      def parse_exit_targets(exits_text)
        exits_text.to_s.split("\r\n").each_with_object({}) do |line, out|
          plain = strip_ansi(line).strip
          next if plain.empty? || plain.start_with?("Obvious exits") || plain.match?(VITALS_RE)

          m = EXIT_LINE_RE.match(plain)
          out[m[1]] = m[2] if m
        end
      end

      # Yellow = mob (also matches the room name, but that's consumed
      # before `past_exits_marker` flips, so it never reaches here). Green =
      # object. A line with neither color (color toggle off, or a server
      # variant) still gets classified as :unknown rather than silently
      # dropped or guessed at — see the plan's "never guess silently" rule.
      def classify_entity(raw_line, plain_text)
        type = if raw_line.include?(YELLOW)
                 :mob
               elsif raw_line.include?(GREEN)
                 :object
               else
                 :unknown
               end
        { type: type, text: plain_text, keyword: guess_keyword(plain_text) }
      end

      # Articles, copulas, and the position-line verbs/prepositions every
      # entity line is built from (§0's positions[] table), plus compass
      # words — a description or entity line ending "...from the west" or
      # "...to the north" should not yield a direction as the keyword.
      STOPWORDS = %w[a an the is are was were standing sitting lying sleeping dead
                     fighting here there ready jump trouble mucking through garbage
                     stands has been installed in wall on with from to of and
                     north east south west up down].freeze

      # A line names a mob/object in prose, not by its command keyword — the
      # keyword is a guess, verified later by whether consider/examine
      # resolves it (see RoomSurvey). Heuristic: take words before the
      # line's first verb-ish token, drop articles/stopwords, try the last
      # remaining word first ("A beastly fido is mucking..." -> "fido").
      def guess_keyword(text)
        words = text.downcase.gsub(/[^a-z\s]/, "").split
        candidates = words.reject { |w| STOPWORDS.include?(w) }
        candidates.last
      end

      def strip_ansi(text)
        text.to_s.gsub(ANSI_RE, "")
      end
    end
  end
end
