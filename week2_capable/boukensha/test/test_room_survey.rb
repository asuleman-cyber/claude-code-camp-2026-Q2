require_relative "helper"
require "boukensha/mud/room_survey"

class TestRoomSurvey < Minitest::Test
  CIRCLE_OF_STONES = "== look ==\n\e[0;33mThe Circle Of Stones\e[0m\r\n   You are at the edge of a circle of stones.\r\n\e[0;36m[ Exits: e ]\e[0m\r\n\e[0;33mThe pit fiend is sitting here.\r\n\e[0m\r\n22H 100M 67V (news) (motd) > \n\n== exits ==\nObvious exits:\r\neast  - Too dark to tell.\r\n\r\n22H 100M 67V (news) (motd) > ".freeze

  THREE_FIDOS = "== look ==\n\e[0;33mThe Common Square\e[0m\r\n   The common square.\r\n\e[0;36m[ Exits: n ]\e[0m\r\n\e[0;33mA beastly fido is mucking through the garbage.\r\n\e[0;33mA beastly fido is mucking through the garbage.\r\n\e[0;33mA beastly fido is mucking through the garbage.\r\n\e[0m\r\n20H 100M 42V (news) (motd) > \n\n== exits ==\nObvious exits:\r\nnorth - The Market Square\r\n\r\n20H 100M 42V (news) (motd) > ".freeze

  def fake_tool(responses)
    calls = []
    tool = lambda do |name, args|
      calls << [name, args]
      responses.fetch([name, args]) { responses.fetch(name) { raise "unexpected call #{name}(#{args.inspect})" } }
    end
    [tool, calls]
  end

  def test_surveys_a_room_with_a_real_mob
    call_tool, calls = fake_tool(
      ["poll", {}] => "",
      ["inspect", {}] => CIRCLE_OF_STONES,
      ["consider", { "target" => "fiend" }] => "You ARE mad!\r\n\r\n22H 100M 67V (news) (motd) > ",
      ["examine", { "target" => "fiend" }] => "It is horrifying.\r\nThe pit fiend is in excellent condition.\r\n\r\n22H 100M 67V (news) (motd) > "
    )

    result = Boukensha::Mud::RoomSurvey.new(call_tool: call_tool).call

    assert_equal "The Circle Of Stones", result[:room][:name]
    assert_equal({ "east" => "Too dark to tell." }, result[:room][:exit_targets])
    assert_equal 1, result[:appraisals].length
    assert_equal "fiend", result[:appraisals].first[:keyword]
    assert_equal "You ARE mad!", result[:appraisals].first[:threat]
    assert_match(/in excellent condition/, result[:appraisals].first[:health])
    assert_equal({ hp: 22, mana: 100, move: 67 }, result[:room][:vitals])
    assert_equal %w[poll inspect consider examine], calls.map(&:first)
  end

  def test_dedupes_identical_mobs_to_one_consider_examine_pair
    call_tool, calls = fake_tool(
      ["poll", {}] => "The cityguard leaves north.\r\n",
      ["inspect", {}] => THREE_FIDOS,
      ["consider", { "target" => "fido" }] => "Easy.\r\n\r\n20H 100M 42V (news) (motd) > ",
      ["examine", { "target" => "fido" }] => "A scruffy dog.\r\nThe fido is in excellent condition.\r\n\r\n20H 100M 42V (news) (motd) > "
    )

    result = Boukensha::Mud::RoomSurvey.new(call_tool: call_tool).call

    assert_equal 1, result[:appraisals].length
    assert_equal 3, result[:appraisals].first[:count]
    assert_match(/cityguard leaves north/, result[:events_text])
    # 4 calls total (poll, inspect, one consider, one examine) regardless of
    # 3 identical mobs — the headline claim from the source plan.
    assert_equal 4, calls.length
  end

  def test_a_keyword_that_never_resolves_is_reported_without_appraisal_details
    call_tool, calls = fake_tool(
      ["poll", {}] => "",
      ["inspect", {}] => THREE_FIDOS,
      "consider" => "Consider killing who?\r\n\r\n20H 100M 42V (news) (motd) > "
    )

    result = Boukensha::Mud::RoomSurvey.new(call_tool: call_tool).call

    assert_equal 3, result[:appraisals].first[:count]
    assert_nil result[:appraisals].first[:keyword]
    assert_nil result[:appraisals].first[:threat]
    refute_match(/examine/, calls.map(&:first).join) # never reaches examine after a consider miss
  end

  def test_keyword_cache_is_reused_across_surveys_and_skips_reverification
    cache = {}
    call_tool, calls = fake_tool(
      ["poll", {}] => "",
      ["inspect", {}] => CIRCLE_OF_STONES,
      ["consider", { "target" => "fiend" }] => "You ARE mad!\r\n\r\n22H 100M 67V (news) (motd) > ",
      ["examine", { "target" => "fiend" }] => "The pit fiend is in excellent condition.\r\n\r\n22H 100M 67V (news) (motd) > "
    )
    survey = Boukensha::Mud::RoomSurvey.new(call_tool: call_tool, keyword_cache: cache)

    survey.call
    assert_equal({ "The pit fiend is sitting here." => "fiend" }, cache)

    calls.clear
    result = survey.call
    # Still re-queries threat/health (volatile) — but the keyword itself is
    # never re-verified via a wasted round trip; cache already has the answer.
    assert_equal %w[poll inspect consider examine], calls.map(&:first)
    assert_equal "You ARE mad!", result[:appraisals].first[:threat]
  end

  def test_a_cached_unresolved_mob_skips_consider_entirely_on_repeat_visits
    cache = { "A beastly fido is mucking through the garbage." => nil }
    call_tool, calls = fake_tool(
      ["poll", {}] => "",
      ["inspect", {}] => THREE_FIDOS
    )

    Boukensha::Mud::RoomSurvey.new(call_tool: call_tool, keyword_cache: cache).call

    assert_equal %w[poll inspect], calls.map(&:first)
  end

  def test_room_with_no_mobs_or_objects_returns_an_empty_appraisal_list
    empty_room = "== look ==\n\e[0;33mAn Empty Room\e[0m\r\n   Nothing here.\r\n\e[0;36m[ Exits: n ]\e[0m\r\n\e[0m\r\n20H 100M 40V (news) (motd) > \n\n== exits ==\nObvious exits:\r\nnorth - Somewhere\r\n\r\n20H 100M 40V (news) (motd) > "
    call_tool, = fake_tool(["poll", {}] => "", ["inspect", {}] => empty_room)

    result = Boukensha::Mud::RoomSurvey.new(call_tool: call_tool).call

    assert_equal "An Empty Room", result[:room][:name]
    assert_empty result[:appraisals]
  end
end
