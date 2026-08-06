require_relative "../helper"
require "mud_monitor/map_layout"

module MudMonitor
  class MapLayoutTest < Minitest::Test
    def room(id, name, first_seen_at)
      { "id" => id, "name" => name, "first_seen_at" => first_seen_at }
    end

    def exit_row(room_id, direction, target_room_id)
      { "room_id" => room_id, "direction" => direction, "target_room_id" => target_room_id }
    end

    def test_empty_rooms_yields_an_empty_layout
      result = MapLayout.layout(rooms: [], exits: [])
      assert_empty result.positioned
      assert_empty result.edges
      assert_empty result.disconnected
    end

    def test_a_single_room_with_no_exits_is_positioned_at_the_origin
      rooms = [room(1, "A", "2026-01-01T00:00:00Z")]
      result = MapLayout.layout(rooms: rooms, exits: [])

      assert_equal 1, result.positioned.length
      entry = result.positioned.first
      assert_equal 1, entry.row
      assert_equal 1, entry.col
      assert_empty result.disconnected
    end

    def test_anchor_is_the_room_with_the_oldest_first_seen_at_regardless_of_input_order
      rooms = [room(2, "Later", "2026-01-02T00:00:00Z"), room(1, "Earliest", "2026-01-01T00:00:00Z")]
      exits = [exit_row(1, "east", 2)]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      earliest = result.positioned.find { |p| p.room["id"] == 1 }
      later    = result.positioned.find { |p| p.room["id"] == 2 }
      assert_equal [earliest.row, earliest.col + 1], [later.row, later.col] # east = +1 col, same row
    end

    def test_north_south_move_the_row_east_west_move_the_column
      rooms = [
        room(1, "Center", "2026-01-01T00:00:00Z"),
        room(2, "North",  "2026-01-01T00:00:01Z"),
        room(3, "South",  "2026-01-01T00:00:02Z"),
        room(4, "East",   "2026-01-01T00:00:03Z"),
        room(5, "West",   "2026-01-01T00:00:04Z")
      ]
      exits = [
        exit_row(1, "north", 2), exit_row(1, "south", 3),
        exit_row(1, "east", 4), exit_row(1, "west", 5)
      ]
      result = MapLayout.layout(rooms: rooms, exits: exits)
      pos = result.positioned.each_with_object({}) { |p, h| h[p.room["id"]] = [p.row, p.col] }

      center, north, south, east, west = pos[1], pos[2], pos[3], pos[4], pos[5]
      assert_equal [center[0] - 1, center[1]], north # north: row - 1
      assert_equal [center[0] + 1, center[1]], south # south: row + 1
      assert_equal [center[0], center[1] + 1], east  # east:  col + 1
      assert_equal [center[0], center[1] - 1], west  # west:  col - 1
    end

    def test_up_and_down_do_not_move_the_room_and_become_badges_instead
      rooms = [room(1, "A", "2026-01-01T00:00:00Z"), room(2, "B", "2026-01-01T00:00:01Z")]
      exits = [exit_row(1, "east", 2), exit_row(1, "up", nil), exit_row(1, "down", 3)]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      a = result.positioned.find { |p| p.room["id"] == 1 }
      b = result.positioned.find { |p| p.room["id"] == 2 }
      assert_equal %w[up down], a.badges
      assert_empty b.badges
      assert_equal [a.row, a.col + 1], [b.row, b.col] # up/down never touched the grid position
    end

    def test_a_room_only_reachable_by_a_one_way_or_vertical_path_is_disconnected
      rooms = [room(1, "A", "2026-01-01T00:00:00Z"), room(2, "Cellar", "2026-01-01T00:00:01Z")]
      exits = [exit_row(1, "down", 2)] # only a vertical link — never positions room 2
      result = MapLayout.layout(rooms: rooms, exits: exits)

      assert_equal [1], result.positioned.map { |p| p.room["id"] }
      assert_equal [2], result.disconnected.map { |r| r["id"] }
    end

    def test_disconnected_room_does_not_shift_the_main_grids_coordinates
      rooms = [
        room(1, "A", "2026-01-01T00:00:00Z"),
        room(2, "B", "2026-01-01T00:00:01Z"), # connected, west of A
        room(3, "Island", "2026-01-01T00:00:02Z") # never linked to anything
      ]
      exits = [exit_row(1, "west", 2)]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      a = result.positioned.find { |p| p.room["id"] == 1 }
      b = result.positioned.find { |p| p.room["id"] == 2 }
      # B is west of A, so normalizing shifts both right by one; the
      # unreachable island room must not factor into that shift at all.
      assert_equal 2, a.col
      assert_equal 1, b.col
      assert_equal [3], result.disconnected.map { |r| r["id"] }
    end

    def test_a_cycle_produces_every_edge_not_just_the_bfs_spanning_tree
      rooms = [
        room(1, "A", "2026-01-01T00:00:00Z"),
        room(2, "B", "2026-01-01T00:00:01Z"),
        room(3, "C", "2026-01-01T00:00:02Z"),
        room(4, "D", "2026-01-01T00:00:03Z")
      ]
      # A loop: A-east->B-south->D-west->C-north->A
      exits = [
        exit_row(1, "east", 2), exit_row(2, "south", 4),
        exit_row(4, "west", 3), exit_row(3, "north", 1)
      ]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      assert_equal 4, result.edges.length
      assert_empty result.disconnected
    end

    # MUD geography is not euclidean: north, east, south, west can leave you
    # somewhere that is not where you started. Two different rooms then want
    # the same grid cell, and a CSS grid would stack them — the second one
    # invisible behind the first while the room count still claims it's on
    # screen.
    def test_two_rooms_never_share_a_grid_cell_when_the_geography_loops_back
      rooms = (1..5).map { |i| room(i, "R#{i}", "2026-01-01T00:00:0#{i}Z") }
      # 1 -north-> 2 -east-> 3 -south-> 4 -west-> 5, and 5 is NOT room 1.
      exits = [
        exit_row(1, "north", 2), exit_row(2, "east", 3),
        exit_row(3, "south", 4), exit_row(4, "west", 5)
      ]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      assert_equal 5, result.positioned.length, "no room may be dropped"
      cells = result.positioned.map { |p| [p.row, p.col] }
      assert_equal cells.length, cells.uniq.length, "every room needs its own cell"
    end

    def test_only_the_room_that_lost_its_true_cell_is_flagged_displaced
      rooms = (1..5).map { |i| room(i, "R#{i}", "2026-01-01T00:00:0#{i}Z") }
      exits = [
        exit_row(1, "north", 2), exit_row(2, "east", 3),
        exit_row(3, "south", 4), exit_row(4, "west", 5)
      ]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      displaced = result.positioned.select(&:displaced).map { |p| p.room["id"] }
      assert_equal [5], displaced
    end

    def test_a_displaced_room_lands_adjacent_to_the_cell_it_wanted
      rooms = (1..5).map { |i| room(i, "R#{i}", "2026-01-01T00:00:0#{i}Z") }
      exits = [
        exit_row(1, "north", 2), exit_row(2, "east", 3),
        exit_row(3, "south", 4), exit_row(4, "west", 5)
      ]
      result = MapLayout.layout(rooms: rooms, exits: exits)

      anchor = result.positioned.find { |p| p.room["id"] == 1 } # the cell room 5 wanted
      bumped = result.positioned.find { |p| p.room["id"] == 5 }
      distance = [(bumped.row - anchor.row).abs, (bumped.col - anchor.col).abs].max
      assert_equal 1, distance, "nearest free cell, not somewhere arbitrary"
    end

    def test_a_layout_with_no_collisions_flags_nothing_as_displaced
      rooms = [room(1, "A", "2026-01-01T00:00:00Z"), room(2, "B", "2026-01-01T00:00:01Z")]
      result = MapLayout.layout(rooms: rooms, exits: [exit_row(1, "east", 2)])

      assert_empty result.positioned.select(&:displaced)
    end

    def test_a_known_exit_to_an_unsurveyed_room_id_is_ignored_not_raised
      rooms = [room(1, "A", "2026-01-01T00:00:00Z")]
      exits = [exit_row(1, "north", 999)] # 999 isn't in `rooms` at all

      result = MapLayout.layout(rooms: rooms, exits: exits)
      assert_equal [1], result.positioned.map { |p| p.room["id"] }
      assert_empty result.edges
    end
  end
end
