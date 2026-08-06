require_relative "../hooks"
require_relative "room_parser"
require_relative "room_survey"
require_relative "fingerprint"
require_relative "state_block"

module Boukensha
  module Mud
    # The Boukensha::Hooks subclass that gives the agent memory — per
    # docs/plans/week_2/basic_memory.md. Wired at the entrypoint
    # (boukensha_loader.rb) where the `inspect_room` tool used to be
    # registered (Phase C); there is no room tool any more — the player's
    # position is established automatically, every iteration.
    #
    # Three things happen across a turn:
    #   after_tool   — cheap, synchronous, no MUD calls: scrapes HP/mana/
    #                  move off any result, and when a `move` succeeds,
    #                  parses + fingerprints it (for identification only —
    #                  see basic_memory.md §5.5, a move result is an index
    #                  key, never a room record) and substitutes a one-line
    #                  stub for what the model sees.
    #   before_tools — one unconditional `poll`, the only moment output
    #                  that arrived while the model was thinking is still
    #                  recoverable (§5.6).
    #   before_model — the reconciliation: resolve current room (cold /
    #                  known-by-fingerprint / new), persist to Store, render
    #                  the state block. The only hook allowed to spend
    #                  blocking MUD round trips, and only when it must.
    #
    # Simplifications versus the source plan (disclosed in this gem's
    # report doc): room identity is weak-fingerprint-only (no arrival-edge
    # disambiguation, no strong-fingerprint tiebreak, ambiguous == treated
    # as new); only `move` gets the fingerprint/substitution treatment
    # (flee/track pass through unchanged); a known room's entity list is
    # shown with cached threat/health but is not re-verified via
    # consider/examine on every revisit (that per-mob round-trip saving
    # from the source plan is not implemented — room-level memory, the
    # bigger win, is).
    class Hooks < Boukensha::Hooks
      VITALS_RE     = /(\d+)H\s+(\d+)M\s+(\d+)V/
      MOVE_TOOL_KEY = "move" # the only tool whose output is fingerprinted (see class doc)

      # error_log: optional Boukensha::ErrorLog (Phase F — error_log.md).
      # Every rescue below used to just swallow the exception (correctly —
      # a broken hook must degrade the agent to "no memory," never crash
      # the turn) but with nowhere to see *that* it happened. This is where
      # those now go instead of vanishing.
      def initialize(call_tool:, store:, keyword_cache: {}, error_log: nil)
        @call_tool           = call_tool
        @store               = store
        @keyword_cache       = keyword_cache
        @error_log           = error_log
        @pending_parsed      = nil # RoomParser result from a move awaiting resolution
        @pending_direction   = nil
        @current_room_id     = nil
        @last_events         = nil
        @last_entities       = []
      end

      def before_tools(calls:, context:)
        events = @call_tool.call("poll", {})
        scrape_vitals(events)
      rescue StandardError => e
        @error_log&.record(e, context: "Mud::Hooks#before_tools")
        nil
      end

      def after_tool(name:, args:, result:, context:)
        scrape_vitals(result)
        return unless move_tool?(name)
        return unless RoomParser.room_shape?(result)

        parsed              = RoomParser.parse(result)
        @pending_parsed     = parsed
        @pending_direction  = args["direction"] || args[:direction]
        "moved #{@pending_direction} → #{parsed[:name]}"
      rescue StandardError => e
        @error_log&.record(e, context: "Mud::Hooks#after_tool(#{name})")
        nil
      end

      def before_model(context:)
        room_id, uncertain = resolve_room!
        render_and_set(context, room_id, uncertain)
      rescue StandardError => e
        # a broken hook degrades the agent to "no memory," never crashes the turn
        @error_log&.record(e, context: "Mud::Hooks#before_model")
        nil
      end

      private

      def move_tool?(name)
        name.to_s.split("__").last == MOVE_TOOL_KEY
      end

      def scrape_vitals(text)
        return unless text

        m = VITALS_RE.match(RoomParser.strip_ansi(text.to_s))
        return unless m

        @store.update_player_state(hp: m[1].to_i, mana: m[2].to_i, move: m[3].to_i)
      rescue StandardError => e
        @error_log&.record(e, context: "Mud::Hooks#scrape_vitals")
        nil
      end

      # Three cases, in ascending cost:
      #   1. No move since the last resolution -> reuse what we already
      #      know. Zero MUD calls, zero DB calls.
      #   2. A move happened -> fingerprint it and look it up. Zero MUD
      #      calls (the fingerprint comes from move output we already have)
      #      unless it's unrecognised, in which case fall through to a full
      #      survey.
      #   3. True cold start (never resolved anything this process) -> a
      #      full survey. There is no shortcut; nothing has told us where we
      #      are yet.
      def resolve_room!
        if @pending_parsed.nil? && @current_room_id
          return [@current_room_id, false]
        end

        if @pending_parsed
          parsed = @pending_parsed
          @pending_parsed = nil
          weak  = Fingerprint.weak(name: parsed[:name], description: parsed[:description],
                                    exit_directions: parsed[:exit_directions])
          match = @store.find_room_by_weak_fingerprint(weak)

          if match.is_a?(Hash)
            link_from_previous(match["id"])
            @store.touch_room(match["id"])
            @current_room_id = match["id"]
            @last_events     = nil
            @last_entities   = entities_from_live_parse(parsed, match["id"])
            return [match["id"], false]
          end

          # Unknown (or ambiguous, simplified to "unknown") — survey it
          # properly rather than trust move output for a permanent record.
          room_id = survey_and_persist!
          link_from_previous(room_id)
          @current_room_id = room_id
          return [room_id, match == :ambiguous]
        end

        # Cold start.
        room_id = survey_and_persist!
        @current_room_id = room_id
        [room_id, false]
      end

      def survey_and_persist!
        data = RoomSurvey.new(call_tool: @call_tool, keyword_cache: @keyword_cache).call
        room = data[:room]
        weak = Fingerprint.weak(name: room[:name], description: room[:description], exit_directions: room[:exit_directions])
        strong = Fingerprint.strong(weak_fingerprint: weak, exit_targets: room[:exit_targets])

        existing = @store.find_room_by_weak_fingerprint(weak)
        room_id =
          if existing.is_a?(Hash)
            @store.touch_room(existing["id"])
            @store.mark_surveyed(existing["id"], strong_fingerprint: strong) unless existing["surveyed_at"]
            existing["id"]
          else
            @store.insert_room(name: room[:name], description: room[:description],
                                weak_fingerprint: weak, strong_fingerprint: strong, surveyed: true)
          end

        room[:exit_targets].each do |direction, target_name|
          @store.upsert_room_exit(room_id: room_id, direction: direction, target_name: target_name)
        end

        data[:appraisals].each do |a|
          entity_id = @store.upsert_entity(kind: "mob", descr: a[:text], keyword: a[:keyword],
                                            threat: a[:threat], health: a[:health])
          @store.upsert_sighting(entity_id: entity_id, room_id: room_id, count: a[:count])
        end
        room[:objects].each do |o|
          entity_id = @store.upsert_entity(kind: "object", descr: o[:text], keyword: o[:keyword])
          @store.upsert_sighting(entity_id: entity_id, room_id: room_id)
        end

        @last_events   = data[:events_text]
        @last_entities = data[:appraisals].map { |a| { text: a[:text], kind: "mob", threat: a[:threat] } } +
                         room[:objects].map { |o| { text: o[:text], kind: "object", threat: nil } }
        room_id
      end

      # Live-parsed mobs/objects from the move that got us here, enriched
      # with cached threat (a free DB read) where we already have it — no
      # consider/examine round trip on a room we already know.
      def entities_from_live_parse(parsed, room_id)
        (parsed[:mobs] + parsed[:objects]).map do |e|
          cached = @store.find_entity(kind: e[:type].to_s, descr: e[:text])
          @store.upsert_sighting(entity_id: cached["id"], room_id: room_id) if cached
          { text: e[:text], kind: e[:type].to_s, threat: cached && cached["threat"] }
        end
      end

      def link_from_previous(target_room_id)
        return unless @pending_direction

        prev_id = @store.player_state && @store.player_state["current_room_id"]
        return unless prev_id && prev_id != target_room_id

        @store.link_exit_target(room_id: prev_id, direction: @pending_direction, target_room_id: target_room_id)
      end

      def render_and_set(context, room_id, uncertain)
        room_row = room_id && @store.find_room(room_id)
        exits = room_id ? @store.room_exits(room_id).map { |e|
          { direction: e["direction"], target_name: e["target_name"], known: !e["target_room_id"].nil? }
        } : []

        player = @store.player_state
        player_hash = player && {
          hp: player["hp"], max_hp: player["max_hp"], mana: player["mana"], move: player["move"],
          level: player["level"], gold: player["gold"], position: player["position"]
        }

        context.state_block = StateBlock.render(
          room: room_row && { name: room_row["name"], description: room_row["description"], visit_count: room_row["visit_count"] },
          exits: exits,
          entities: @last_entities,
          events: @last_events,
          player_state: player_hash,
          uncertain: uncertain
        )

        return unless room_id

        @store.update_player_state(current_room_id: room_id, last_direction: @pending_direction)
      end
    end
  end
end
