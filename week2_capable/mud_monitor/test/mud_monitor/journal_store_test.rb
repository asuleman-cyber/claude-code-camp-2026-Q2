require_relative "../helper"
require "tmpdir"
require "json"
require "mud_monitor/journal_store"

module MudMonitor
  class JournalStoreTest < Minitest::Test
    def write(dir, date, records)
      lines = records.map { |r| JSON.generate(r) }
      File.write(File.join(dir, "#{date}.jsonl"), lines.join("\n") + "\n")
    end

    def test_disabled_when_dir_missing
      store = JournalStore.new(File.join(Dir.mktmpdir, "nope"))
      refute store.enabled?
      assert_empty store.recent
    end

    def test_reads_upsert_and_event_records
      Dir.mktmpdir do |dir|
        write(dir, "20260801", [
          { seq: 1, at: "2026-08-01T00:00:00Z", stream: "player", key: "hp", from: 20, to: 15 },
          { seq: 2, at: "2026-08-01T00:00:01Z", stream: "room", op: "discovered", room_id: 1, name: "Market Square" }
        ])
        store = JournalStore.new(dir)
        entries = store.recent

        assert_equal 2, entries.length
        assert_equal "hp", entries[0].key
        assert_equal 15, entries[0].to
        assert_equal "discovered", entries[1].op
        assert_equal "Market Square", entries[1].extra["name"]
      end
    end
  end
end
