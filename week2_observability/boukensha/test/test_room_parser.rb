require_relative "helper"
require "boukensha/mud/room_parser"

# Fixtures below are verbatim captures from the live CircleMUD this project
# targets (not hand-written), per the source plan's own testing guidance
# (docs/plans/week_2/scripted_room_survey.md §8.1: "build the parser tests
# from these rather than hand-written fixtures").
class TestRoomParser < Minitest::Test
  P = Boukensha::Mud::RoomParser

  # A room with a green (object) entity line and a dark, unnamed exit —
  # real capture, "A Dark Path".
  DARK_PATH = "== look ==\n\e[0;33mA Dark Path\e[0m\r\n   This narrow path leads through the overhanging trees in the unnatural\r\ndarkness.\r\n   The path appears to continue east and west.\r\n\e[0;36m[ Exits: e w ]\e[0m\r\n\e[0;32m\e[0;32mThere is a strange glow coming from the west.\r\n\e[0m\r\n22H 100M 68V (news) (motd) > \n\n== exits ==\nObvious exits:\r\neast  - Too dark to tell.\r\nwest  - The Circle Of Stones\r\n\r\n22H 100M 68V (news) (motd) > ".freeze

  # A room with a yellow (mob) entity line — real capture, "The Circle Of
  # Stones", containing a pit fiend. This is the case that matters most:
  # the room name is ALSO yellow, so position (first line vs. after the
  # exits marker) is what disambiguates it from a mob.
  CIRCLE_OF_STONES = "== look ==\n\e[0;33mThe Circle Of Stones\e[0m\r\n   You are at the edge of a circle of seven large monolith-like stones.\r\n\e[0;36m[ Exits: e ]\e[0m\r\n\e[0;33mThe pit fiend is sitting here.\r\n\e[0m\r\n22H 100M 67V (news) (motd) > \n\n== exits ==\nObvious exits:\r\neast  - Too dark to tell.\r\n\r\n22H 100M 67V (news) (motd) > ".freeze

  def test_parses_name_description_vitals_and_exit_targets
    result = P.parse(DARK_PATH)

    assert_equal "A Dark Path", result[:name]
    assert_match(/overhanging trees/, result[:description])
    assert_match(/continue east and west/, result[:description])
    assert_equal({ hp: 22, mana: 100, move: 68 }, result[:vitals])
    assert_equal({ "east" => "Too dark to tell.", "west" => "The Circle Of Stones" }, result[:exit_targets])
  end

  def test_green_line_classifies_as_object
    result = P.parse(DARK_PATH)

    assert_equal 1, result[:objects].length
    assert_equal 0, result[:mobs].length
    assert_match(/strange glow/, result[:objects].first[:text])
  end

  def test_yellow_line_after_exits_marker_classifies_as_mob_not_the_room_name
    result = P.parse(CIRCLE_OF_STONES)

    assert_equal "The Circle Of Stones", result[:name]
    assert_equal 1, result[:mobs].length
    assert_equal "The pit fiend is sitting here.", result[:mobs].first[:text]
    assert_equal "fiend", result[:mobs].first[:keyword]
  end

  def test_keyword_guess_drops_articles_and_position_verbs
    assert_equal "fido", P.guess_keyword("A beastly fido is mucking through the garbage.")
    assert_equal "cityguard", P.guess_keyword("A cityguard stands here.")
    assert_equal "fiend", P.guess_keyword("The pit fiend is sitting here.")
  end

  def test_keyword_guess_does_not_pick_a_compass_word
    guess = P.guess_keyword("There is a strange glow coming from the west.")
    refute_equal "west", guess
  end

  def test_missing_look_or_exits_section_does_not_raise
    look_only = "== look ==\n\e[0;33mSome Room\e[0m\r\n   desc.\r\n\e[0;36m[ Exits: n ]\e[0m\r\n20H 100M 40V (news) (motd) > "
    result = P.parse(look_only)

    assert_equal "Some Room", result[:name]
    assert_empty result[:exit_targets]
  end

  def test_split_sections
    look, exits = P.split_sections(DARK_PATH)
    assert_match(/A Dark Path/, look)
    assert_match(/Obvious exits/, exits)
  end

  def test_strip_ansi_removes_all_escape_codes
    assert_equal "A Dark Path", P.strip_ansi("\e[0;33mA Dark Path\e[0m")
  end
end
