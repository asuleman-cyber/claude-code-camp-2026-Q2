module Boukensha
  module Tools
    # Pure text → Hash. No I/O, no network, no LLM — every field here is
    # mechanically derivable from the MUD's own output, per
    # docs/plans/week_2/scripted_room_survey.md §3.2/§3.3 (colleague repo).
    #
    # Takes the raw text from the `inspect` MCP tool (mud_manager's
    # look+exits composite, see Phase A) and splits it into the room's
    # identity, description, vitals, exit map, and entity lines classified
    # by color — verified against tbaMUD source (`act.informative.c`):
    # ground objects print in green (`CCGRN`, `\e[0;32m`), mobs and the room
    # name itself print in yellow (`CCYEL`, `\e[0;33m`); position (first
    # line vs. after the exits marker) disambiguates the room name from a
    # mob.
    #
    # Deliberately does NOT attempt `look_candidates` (hidden/examinable
    # nouns in the prose) — that is the one genuinely fuzzy field in the
    # source plan, and out of scope for this pass (see
    # docs/plans/week2_catchup_plan.md Phase C).
    module RoomParser
      YELLOW = "\e[0;33m"
      GREEN  = "\e[0;32m"
      CYAN   = "\e[0;36m"

      ANSI_RE      = /\e\[[0-9;]*m/
      EXITS_MARKER_RE = /\[\s*Exits:/
      VITALS_RE    = /(\d+)H\s+(\d+)M\s+(\d+)V/
      EXIT_LINE_RE = /\A(\w+)\s*-\s*(.+?)\s*\z/

      module_function

      # inspect_text: the raw string the `inspect` MCP tool returns —
      # "== look ==\n<look output>\n\n== exits ==\n<exits output>".
      def parse(inspect_text)
        look_text, exits_text = split_sections(inspect_text.to_s)

        name              = nil
        description_lines = []
        entities          = []
        vitals            = nil
        past_exits_marker = false

        look_text.split("\r\n").each do |raw_line|
          plain = strip_ansi(raw_line).strip

          if name.nil?
            next if plain.empty?

            name = plain
            next
          end

          if !past_exits_marker && plain =~ EXITS_MARKER_RE
            past_exits_marker = true
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

        {
          name: name,
          description: description_lines.join(" ").gsub(/\s+/, " ").strip,
          vitals: vitals,
          mobs: entities.select { |e| e[:type] == :mob },
          objects: entities.select { |e| e[:type] == :object },
          exit_targets: parse_exit_targets(exits_text)
        }
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
