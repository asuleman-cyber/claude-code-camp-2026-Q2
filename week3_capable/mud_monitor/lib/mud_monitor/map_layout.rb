module MudMonitor
  # Pure function: rooms + exits in, positioned rooms + edges out. No I/O,
  # no DB — docs/plans/player_map_plan.md Part 2 Step 7. Takes the exact row
  # shapes KnowledgeStore already returns (string-keyed Hashes: rooms need
  # "id", "name", "first_seen_at"; exits need "room_id", "direction",
  # "target_room_id") so the /knowledge/map route can pass its store reads
  # straight through, and so tests can build synthetic fixtures in the same
  # shape without a fake DB.
  #
  # BFS from the earliest-recorded room (oldest first_seen_at — the natural
  # start-of-exploration anchor, per the plan). North/south move the row,
  # east/west move the column — "north is north," not a force-directed
  # guess. Up/down are never a grid axis: a room's up/down exits show up as
  # `badges` on its positioned entry instead of moving it anywhere.
  #
  # A room not reachable from the anchor via north/south/east/west edges
  # (only reachable by up/down, a one-way exit, or a genuinely separate
  # area) is never silently dropped and never mis-placed into the main
  # grid's coordinate space — it comes back in `disconnected`.
  #
  # MUD geography is not euclidean. Walking north, east, south, west does
  # not reliably return you to where you started, so two genuinely
  # different rooms can land on the same [row, col]. A CSS grid renders
  # both in one cell, stacked — the second room silently disappears behind
  # the first while the room count still claims it's there. So a cell that
  # is already taken is never reused: the room spirals out to the nearest
  # free cell instead and is flagged `displaced`, which the map view draws
  # differently. Its position is then a lie about geometry but an honest
  # one about existence, which is the right trade for a debugging view —
  # and the flag says which rooms to distrust.
  module MapLayout
    CARDINAL_OFFSETS = {
      "north" => [-1, 0],
      "south" => [1, 0],
      "east"  => [0, 1],
      "west"  => [0, -1]
    }.freeze

    VERTICAL = %w[up down].freeze

    Result = Struct.new(:positioned, :edges, :disconnected, keyword_init: true)
    Positioned = Struct.new(:room, :row, :col, :badges, :displaced, keyword_init: true)
    Edge = Struct.new(:from_id, :to_id, :direction, keyword_init: true)

    module_function

    def layout(rooms:, exits:)
      return Result.new(positioned: [], edges: [], disconnected: []) if rooms.empty?

      by_id = rooms.each_with_object({}) { |r, h| h[r["id"]] = r }
      anchor = rooms.min_by { |r| r["first_seen_at"].to_s }

      positions, displaced = bfs_positions(anchor:, exits:, by_id:)
      edges                = cardinal_edges(exits:, positions:)
      badges               = vertical_badges(exits:)

      positioned = normalize(positions).map do |id, (row, col)|
        Positioned.new(room: by_id.fetch(id), row: row, col: col,
                       badges: badges[id] || [], displaced: displaced.include?(id))
      end

      disconnected = rooms.reject { |r| positions.key?(r["id"]) }

      Result.new(positioned: positioned, edges: edges, disconnected: disconnected)
    end

    # One pass of breadth-first search over cardinal-direction edges only
    # (up/down and any exit whose target isn't known yet are not
    # traversable — they don't move the search anywhere). The first room
    # reached at each id wins its position; a later alternate path to an
    # already-positioned room only contributes an edge (see cardinal_edges),
    # never a reposition — keeps the layout deterministic even when the
    # explored graph has cycles.
    #
    # Returns [positions, displaced_ids]. A room whose natural cell is
    # already occupied by a different room gets the nearest free cell and
    # its id in `displaced` (see module doc).
    def bfs_positions(anchor:, exits:, by_id:)
      positions = { anchor["id"] => [0, 0] }
      occupied  = { [0, 0] => anchor["id"] }
      displaced = []
      queue     = [anchor["id"]]

      by_room = exits.group_by { |e| e["room_id"] }

      until queue.empty?
        current = queue.shift
        row, col = positions[current]

        (by_room[current] || []).each do |e|
          offset = CARDINAL_OFFSETS[e["direction"]]
          target = e["target_room_id"]
          next unless offset && target && by_id.key?(target)
          next if positions.key?(target)

          desired = [row + offset[0], col + offset[1]]
          cell    = occupied.key?(desired) ? nearest_free_cell(desired, occupied) : desired
          displaced << target unless cell == desired

          positions[target] = cell
          occupied[cell]    = target
          queue << target
        end
      end

      [positions, displaced]
    end
    private_class_method :bfs_positions

    # Rings of increasing Chebyshev radius around the desired cell, each
    # ring scanned in a fixed order, first free cell wins. Deterministic
    # (same input always lays out the same way) and always terminates: each
    # ring holds 8r cells and only finitely many are ever occupied.
    def nearest_free_cell(desired, occupied)
      row, col = desired
      radius = 1

      loop do
        (-radius..radius).each do |dr|
          (-radius..radius).each do |dc|
            # Only the ring's perimeter — the interior was scanned already.
            next unless dr.abs == radius || dc.abs == radius

            candidate = [row + dr, col + dc]
            return candidate unless occupied.key?(candidate)
          end
        end
        radius += 1
      end
    end
    private_class_method :nearest_free_cell

    # Every cardinal exit between two POSITIONED rooms becomes an edge for
    # the grid to render as a connecting border — not just the BFS
    # spanning-tree edges, so a cycle in the explored map (e.g. a loop of
    # four rooms) still shows all four connections, not just three.
    def cardinal_edges(exits:, positions:)
      exits.each_with_object([]) do |e, out|
        next unless CARDINAL_OFFSETS.key?(e["direction"])

        from, to = e["room_id"], e["target_room_id"]
        next unless to && positions.key?(from) && positions.key?(to)

        out << Edge.new(from_id: from, to_id: to, direction: e["direction"])
      end
    end
    private_class_method :cardinal_edges

    # room_id -> ["up", "down"] (whichever vertical directions that room has
    # an exit in, known destination or not — the badge means "there is a
    # way up/down here," not "the destination is mapped").
    def vertical_badges(exits:)
      exits.each_with_object({}) do |e, out|
        next unless VERTICAL.include?(e["direction"])

        (out[e["room_id"]] ||= []) << e["direction"]
      end
    end
    private_class_method :vertical_badges

    # Shifts every position so the minimum row/col is 1 — CSS grid-row/
    # grid-column are 1-indexed, and BFS offsets are free to go negative
    # (north/west of the anchor).
    def normalize(positions)
      return positions if positions.empty?

      min_row = positions.values.map(&:first).min
      min_col = positions.values.map(&:last).min

      positions.transform_values { |(row, col)| [row - min_row + 1, col - min_col + 1] }
    end
    private_class_method :normalize
  end
end
