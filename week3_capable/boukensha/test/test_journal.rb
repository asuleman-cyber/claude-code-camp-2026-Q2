require_relative "helper"
require "tmpdir"
require "json"
require "boukensha/mud/memory/journal"

class TestJournal < Minitest::Test
  def test_from_env_is_nil_when_unset
    old = ENV.delete("MUD_JOURNAL_DIR")
    assert_nil Boukensha::Mud::Memory::Journal.from_env
  ensure
    ENV["MUD_JOURNAL_DIR"] = old if old
  end

  def test_upsert_writes_on_first_value
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      wrote = journal.upsert(stream: "player", key: "level", value: 1)

      assert wrote
      record = read_records(dir).first
      assert_nil record["from"]
      assert_equal 1, record["to"]
    end
  end

  def test_upsert_is_a_noop_when_value_is_unchanged
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      journal.upsert(stream: "player", key: "hp", value: 20)
      wrote = journal.upsert(stream: "player", key: "hp", value: 20)

      refute wrote
      assert_equal 1, read_records(dir).length
    end
  end

  def test_upsert_writes_again_when_value_changes
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      journal.upsert(stream: "player", key: "hp", value: 20)
      journal.upsert(stream: "player", key: "hp", value: 15)

      records = read_records(dir)
      assert_equal 2, records.length
      assert_equal 20, records[0]["to"]
      assert_equal 20, records[1]["from"]
      assert_equal 15, records[1]["to"]
    end
  end

  def test_different_keys_are_tracked_independently
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      journal.upsert(stream: "player", key: "hp", value: 20)
      journal.upsert(stream: "player", key: "mana", value: 100)

      assert_equal 2, read_records(dir).length
    end
  end

  def test_event_always_writes
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      journal.event(stream: "room", op: "discovered", room_id: 1, name: "Market Square")
      journal.event(stream: "room", op: "discovered", room_id: 1, name: "Market Square")

      assert_equal 2, read_records(dir).length # events are not deduped like upserts
    end
  end

  def test_seq_increments_across_writes
    Dir.mktmpdir do |dir|
      journal = Boukensha::Mud::Memory::Journal.new(dir)
      journal.upsert(stream: "player", key: "hp", value: 20)
      journal.upsert(stream: "player", key: "hp", value: 15)

      assert_equal [1, 2], read_records(dir).map { |r| r["seq"] }
    end
  end

  private

  def read_records(dir)
    Dir.glob(File.join(dir, "*.jsonl")).sort.flat_map { |f| File.readlines(f).map { |l| JSON.parse(l) } }
  end
end
