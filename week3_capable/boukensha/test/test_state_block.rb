require_relative "helper"
require "boukensha/mud/state_block"

class TestStateBlock < Minitest::Test
  SB = Boukensha::Mud::StateBlock

  def test_renders_a_full_block
    text = SB.render(
      room: { name: "Market Square", description: "busy square", visit_count: 2 },
      exits: [{ direction: "north", target_name: "The Temple Square", known: true }],
      entities: [{ text: "A cityguard stands here.", kind: "mob", threat: "you could take him" }],
      events: "The Mayor has arrived.",
      player_state: { hp: 20, max_hp: 20, mana: 100, move: 81, level: 1, gold: 43, position: "standing" }
    )

    assert_match(/\[here\] Market Square  \(visit 2\)/, text)
    assert_match(/north→The Temple Square ✓/, text)
    assert_match(/A cityguard stands here\. \(mob — you could take him\)/, text)
    assert_match(/events: The Mayor has arrived\./, text)
    assert_match(/you: 20\/20hp/, text)
  end

  def test_description_only_shown_on_first_visit
    first = SB.render(room: { name: "R", description: "prose", visit_count: 1 })
    second = SB.render(room: { name: "R", description: "prose", visit_count: 2 })

    assert_match(/description: prose/, first)
    refute_match(/description:/, second)
  end

  def test_unknown_exit_gets_a_question_mark_known_exit_gets_a_check
    text = SB.render(
      room: { name: "R", description: "", visit_count: 1 },
      exits: [
        { direction: "north", target_name: "A", known: true },
        { direction: "south", target_name: nil, known: false }
      ]
    )

    assert_match(/north→A ✓/, text)
    assert_match(/south→\? \?/, text)
  end

  def test_no_room_renders_an_honest_placeholder_not_a_guess
    assert_equal "[here] unknown — no room established yet", SB.render(room: nil)
  end

  def test_uncertain_room_says_so_instead_of_a_confident_lie
    text = SB.render(room: { name: "Dark Alley", description: "", visit_count: 1 }, uncertain: true)
    assert_match(/\[here\] Dark Alley \(uncertain\)/, text)
  end

  def test_events_omitted_when_blank
    text = SB.render(room: { name: "R", description: "", visit_count: 2 }, events: "")
    refute_match(/events:/, text)
  end

  def test_no_entities_omits_the_here_line
    text = SB.render(room: { name: "R", description: "", visit_count: 2 }, entities: [])
    refute_match(/here:/, text)
  end
end
