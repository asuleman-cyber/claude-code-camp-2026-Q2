module Boukensha
  module Mud
    # `world_knowledge` — the one native, read-only tool over the room graph
    # Phase D has been accumulating in knowledge.sqlite3.
    #
    # Until Phase H that graph only ever reached a model one way: Mud::Hooks
    # rendering the *current* room as a state block, every iteration, whether
    # or not anything wanted it. Nothing could ask about a room it wasn't
    # standing in, and nothing could ask whether two rooms connect. This tool
    # is the ask side of the same data.
    #
    # It is not an MCP server. The reference design moved its equivalent out
    # to a separate `log_viz --mcp` process; here the store is already open
    # in-process (the loader hands the very same Store instance Mud::Hooks
    # writes through), so a stdio hop would buy isolation nothing needs and
    # cost a subprocess, a handshake, and a second file handle on a SQLite
    # database this process already holds.
    #
    # Read-only in the strong sense: every Store method it calls is a SELECT,
    # and it never touches the MUD. Asking about the world cannot change it,
    # so an over-curious subagent wastes tokens and nothing else.
    module KnowledgeTool
      NAME = "world_knowledge".freeze

      KINDS = %w[overview room route].freeze

      DESCRIPTION = <<~DESC.strip
        Look up what has already been learned about the world map — rooms visited, how they connect, and what was seen in them. Reads remembered knowledge only; it never looks at the MUD, so it cannot see anything happening right now and never moves the character.

        kind=overview (default): how much of the world is known, and where the character is.
        kind=room, name=<room name>: what is known about that room — its description, its exits and where they lead, and what has been seen there. Omit name for the current room.
        kind=route, to=<room name>: the shortest already-walked route from the current room to that one. Only returns a route built from moves actually made before; an unexplored exit is not a route.
      DESC

      PARAMETERS = {
        kind: { type: "string", description: "What to look up (one of: #{KINDS.join(", ")}). Defaults to overview." },
        name: { type: "string", description: "Room name, for kind=room. Omit for the current room." },
        to:   { type: "string", description: "Destination room name, for kind=route." }
      }.freeze

      # registry: a Registry or RunDSL — anything with #tool.
      # store:    an open Mud::Memory::Store.
      #
      # Returns the registered tool, or nil if `permissions` filtered it out
      # (Registry#tool is the single gate; this module never second-guesses it).
      def self.register(registry, store:)
        registry.tool(NAME, description: DESCRIPTION, parameters: PARAMETERS) do |kind: nil, name: nil, to: nil|
          call(store: store, kind: kind, name: name, to: to)
        end
      end

      def self.call(store:, kind: nil, name: nil, to: nil)
        case normalize(kind)
        when "room"  then room(store, name)
        when "route" then route(store, to)
        else overview(store)
        end
      rescue StandardError => e
        # Same posture as Mud::Hooks: knowledge failing degrades the caller to
        # "doesn't know", never crashes its turn.
        "world knowledge unavailable (#{e.class}: #{e.message})"
      end

      def self.normalize(kind)
        k = kind.to_s.strip.downcase
        KINDS.include?(k) ? k : "overview"
      end

      # ---- overview ------------------------------------------------------

      def self.overview(store)
        counts  = store.counts
        current = current_room(store)
        lines   = ["known world: #{counts[:rooms]} rooms, #{counts[:entities]} distinct things seen, " \
                   "#{counts[:frontiers]} unexplored exits"]
        lines << if current
                   "currently in: #{current["name"]} (room #{current["id"]}, visited #{current["visit_count"]}x)"
                 else
                   "current room: unknown (nothing resolved yet this session)"
                 end
        lines.join("\n")
      end

      # ---- room ----------------------------------------------------------

      def self.room(store, name)
        asked = name.to_s.strip

        # "no such room" and "I don't know where I am" are different answers
        # and must not share a message — the first means the name was wrong,
        # the second means nothing has been resolved yet this session.
        if asked.empty?
          target = current_room(store)
          return "current room: unknown (nothing resolved yet this session)" if target.nil?
        else
          target = resolve_room(store, asked)
          return "no room called #{asked.inspect} has been visited." if target.nil?
        end
        return target if target.is_a?(String) # ambiguity message

        lines = ["#{target["name"]} (room #{target["id"]}, visited #{target["visit_count"]}x)"]
        lines << target["description"].to_s.strip unless target["description"].to_s.strip.empty?

        exits = store.room_exits(target["id"])
        lines << if exits.empty?
                   "exits: none recorded"
                 else
                   "exits: " + exits.map { |e| format_exit(store, e) }.join(" | ")
                 end

        entities = store.room_entities(target["id"])
        unless entities.empty?
          lines << "seen here: " + entities.map { |e| format_entity(e) }.join("; ")
        end

        lines.join("\n")
      end

      def self.format_exit(store, exit)
        target_id = exit["target_room_id"]
        if target_id
          room = store.find_room(target_id)
          "#{exit["direction"]}→#{room ? room["name"] : "room #{target_id}"} ✓"
        else
          # The frontier: an exit seen but never walked. Naming it as
          # unexplored is the point — it is what turns "where can I go?"
          # into a decision rather than a guess.
          "#{exit["direction"]}→#{exit["target_name"] || "?"} (unexplored)"
        end
      end

      def self.format_entity(entity)
        bits = [entity["descr"].to_s.strip]
        bits << entity["kind"]
        bits << entity["threat"] if entity["threat"]
        "#{bits.shift} (#{bits.compact.join(" — ")})"
      end

      # ---- route ---------------------------------------------------------

      def self.route(store, to)
        return "kind=route needs a destination room name in `to`." if to.to_s.strip.empty?

        from = current_room(store)
        return "cannot route: the current room is unknown." if from.nil?

        target = resolve_room(store, to)
        return target if target.is_a?(String)
        return "no room called #{to.inspect} has been visited." if target.nil?

        steps = store.route_to(from_id: from["id"], to_id: target["id"])
        return "already in #{target["name"]}." if steps == []
        if steps.nil?
          return "no known route from #{from["name"]} to #{target["name"]} — " \
                 "the rooms in between have not been walked yet."
        end

        "route from #{from["name"]} to #{target["name"]} (#{steps.size} step#{"s" if steps.size != 1}): " +
          steps.map { |s| "#{s[:direction]}→#{s[:name]}" }.join(", ")
      end

      # ---- shared --------------------------------------------------------

      def self.current_room(store)
        state = store.player_state
        id    = state && state["current_room_id"]
        id && store.find_room(id)
      end

      # A room Hash, nil (no match), or a String message (ambiguous). The
      # model supplies a name it read in prose, so more than one match is a
      # normal outcome, not an error — say so and let it pick.
      def self.resolve_room(store, name)
        matches = store.find_rooms_by_name(name)
        case matches.length
        when 0 then nil
        when 1 then matches.first
        else
          "#{matches.length} rooms match #{name.to_s.strip.inspect}: " +
            matches.map { |r| "#{r["name"]} (room #{r["id"]})" }.join(", ") +
            ". Ask again with the exact name."
        end
      end
    end
  end
end
