require_relative "../helper"
require "tmpdir"
require "json"
require "mud_monitor/manager_log"

module MudMonitor
  class ManagerLogStoreTest < Minitest::Test
    def write(dir, date, records)
      lines = records.map { |r| JSON.generate(r) }
      File.write(File.join(dir, "#{date}.jsonl"), lines.join("\n") + "\n")
    end

    def test_disabled_when_dir_missing
      store = ManagerLogStore.new(File.join(Dir.mktmpdir, "does_not_exist"))
      refute store.enabled?
      assert_empty store.dates
      assert_empty store.recent
    end

    def test_reads_records_from_the_latest_date_by_default
      Dir.mktmpdir do |dir|
        write(dir, "20260801", [{ "seq" => 0, "tool" => "look", "mode" => "command" }])
        write(dir, "20260802", [{ "seq" => 0, "tool" => "move", "mode" => "command" }])
        store = ManagerLogStore.new(dir)

        assert_equal %w[20260802 20260801], store.dates
        entries = store.recent
        assert_equal 1, entries.length
        assert_equal "move", entries.first.tool
      end
    end

    def test_recent_respects_limit_and_keeps_the_newest
      Dir.mktmpdir do |dir|
        records = (0...10).map { |i| { "seq" => i, "tool" => "look#{i}" } }
        write(dir, "20260801", records)
        store = ManagerLogStore.new(dir)

        entries = store.recent(limit: 3)
        assert_equal %w[look7 look8 look9], entries.map(&:tool)
      end
    end

    def test_skips_corrupt_lines
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20260801.jsonl"), %({"seq":0,"tool":"look"}\nnot json\n))
        store = ManagerLogStore.new(dir)

        entries = store.recent
        assert_equal 1, entries.length
        assert_equal "look", entries.first.tool
      end
    end

    def test_live_reflects_file_mtime
      Dir.mktmpdir do |dir|
        write(dir, "20260801", [{ "seq" => 0 }])
        store = ManagerLogStore.new(dir)
        assert store.live?

        File.utime(Time.now - 3600, Time.now - 3600, File.join(dir, "20260801.jsonl"))
        refute store.live?
      end
    end
  end
end
