require_relative "room_parser"

module Boukensha
  module Tools
    # Deterministic replacement for an LLM-driven room_inspector ReAct loop
    # — per docs/plans/week2_catchup_plan.md Phase C, that subagent was
    # never built in this fork; this goes straight to the destination the
    # source plan (scripted_room_survey.md) argues for. Zero LLM calls in
    # the warm path: the sequence is fixed (poll -> inspect -> per-distinct-
    # mob consider/examine), and the only data-dependent step — which mobs
    # are here — is exactly what RoomParser's color-based classification
    # already answers deterministically.
    #
    # Drives already-registered MUD tools via an injected `call_tool`
    # lambda (`->(name, args) { result_text }`) rather than spawning its own
    # MCP session — see boukensha_loader.rb, which wires this to
    # `registry.dispatch` (via RunDSL#dispatch) so the survey's tool calls
    # go through the same allow: gate the player's own tools do (Phase A).
    class RoomSurvey
      # Verified against the live server (not assumed from the reference
      # plan, which guessed "They aren't here." for both — wrong for this
      # MUD): a keyword that resolves to nothing gets a different message
      # per command.
      MISS_PATTERNS = {
        consider: /Consider (killing )?who\?/i,
        examine:  /You do not see that here\.?/i
      }.freeze

      # keyword_cache: an external Hash the caller can persist across
      # surveys (mob description text -> verified keyword, or nil for
      # "guessed wrong, don't retry"). Caches the *mapping*, not the
      # reading — threat/health stay volatile and are re-queried every
      # visit, per the source plan's caching rule.
      def initialize(call_tool:, keyword_cache: {})
        @call_tool     = call_tool
        @keyword_cache = keyword_cache
      end

      def call
        events_text = @call_tool.call("poll", {})
        room        = RoomParser.parse(@call_tool.call("inspect", {}))
        appraisals  = appraise_mobs(room[:mobs])

        format_summary(room: room, appraisals: appraisals, events_text: events_text)
      end

      private

      # Dedupe by description text so three identical fidos cost one
      # consider/examine pair, not three — the group's shared count is
      # reported alongside the single appraisal.
      def appraise_mobs(mobs)
        mobs.group_by { |m| m[:text] }.map do |text, group|
          appraise_one(text: text, keyword_guess: group.first[:keyword]).merge(text: text, count: group.size)
        end
      end

      def appraise_one(text:, keyword_guess:)
        if @keyword_cache.key?(text)
          keyword = @keyword_cache[text]
          return unresolved unless keyword

          return appraise_with(keyword)
        end

        unless keyword_guess
          @keyword_cache[text] = nil
          return unresolved
        end

        threat_text = @call_tool.call("consider", { "target" => keyword_guess })
        if miss?(:consider, threat_text)
          @keyword_cache[text] = nil
          return unresolved
        end

        @keyword_cache[text] = keyword_guess
        health_text = @call_tool.call("examine", { "target" => keyword_guess })
        { keyword: keyword_guess, threat: clean_line(threat_text), health: extract_health(health_text) }
      end

      def appraise_with(keyword)
        threat_text = @call_tool.call("consider", { "target" => keyword })
        health_text = @call_tool.call("examine", { "target" => keyword })
        { keyword: keyword, threat: clean_line(threat_text), health: extract_health(health_text) }
      end

      def unresolved
        { keyword: nil, threat: nil, health: nil }
      end

      def miss?(kind, text)
        MISS_PATTERNS.fetch(kind).match?(text.to_s)
      end

      def clean_line(text)
        RoomParser.strip_ansi(text.to_s).split("\r\n").map(&:strip).reject(&:empty?).first
      end

      def extract_health(text)
        lines = RoomParser.strip_ansi(text.to_s).split("\r\n").map(&:strip).reject(&:empty?)
        lines.find { |l| l =~ /condition/i } || lines.first
      end

      def format_summary(room:, appraisals:, events_text:)
        lines = ["[here] #{room[:name] || "unknown room"}"]
        lines << "exits: #{format_exits(room[:exit_targets])}" if room[:exit_targets]&.any?
        lines << "description: #{room[:description]}" unless room[:description].to_s.empty?
        lines << "mobs: #{appraisals.map { |a| format_mob(a) }.join(" | ")}" if appraisals.any?
        lines << "objects: #{room[:objects].map { |o| o[:text] }.join(" | ")}" if room[:objects]&.any?

        events = clean_line_all(events_text)
        lines << "events: #{events}" unless events.empty?

        if room[:vitals]
          v = room[:vitals]
          lines << "you: #{v[:hp]}hp #{v[:mana]}mana #{v[:move]}mv"
        end

        lines.join("\n")
      end

      def format_exits(exit_targets)
        exit_targets.map { |dir, dest| "#{dir}→#{dest}" }.join(" | ")
      end

      def format_mob(appraisal)
        count_suffix = appraisal[:count] > 1 ? " x#{appraisal[:count]}" : ""
        details = [appraisal[:threat], appraisal[:health]].compact
        details.empty? ? "#{appraisal[:text]}#{count_suffix}" : "#{appraisal[:text]}#{count_suffix} (#{details.join("; ")})"
      end

      def clean_line_all(text)
        RoomParser.strip_ansi(text.to_s).split("\r\n").map(&:strip).reject(&:empty?).join(" / ")
      end
    end
  end
end
