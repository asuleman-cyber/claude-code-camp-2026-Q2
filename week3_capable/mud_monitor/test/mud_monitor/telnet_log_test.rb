require_relative "../helper"
require "tmpdir"
require "json"
require "mud_monitor/telnet_log"

module MudMonitor
  class TelnetLogStoreTest < Minitest::Test
    def write(dir, date, records)
      lines = records.map { |r| JSON.generate(r) }
      File.write(File.join(dir, "#{date}.jsonl"), lines.join("\n") + "\n")
    end

    def test_disabled_when_dir_missing
      store = TelnetLogStore.new(File.join(Dir.mktmpdir, "nope"))
      refute store.enabled?
    end

    def test_reads_and_exposes_direction
      Dir.mktmpdir do |dir|
        write(dir, "20260801", [
          { "seq" => 0, "dir" => "out", "text" => "look", "bytes" => 4 },
          { "seq" => 1, "dir" => "in", "text" => "The Common Square", "bytes" => 18 }
        ])
        store = TelnetLogStore.new(dir)
        entries = store.recent
        assert_equal %w[out in], entries.map(&:dir)
        assert_equal "look", entries.first.text
      end
    end

    def test_redacted_entries_carry_the_flag
      Dir.mktmpdir do |dir|
        write(dir, "20260801", [{ "seq" => 0, "dir" => "out", "text" => "<redacted>", "redacted" => true }])
        store = TelnetLogStore.new(dir)
        assert store.recent.first.redacted
      end
    end
  end
end
