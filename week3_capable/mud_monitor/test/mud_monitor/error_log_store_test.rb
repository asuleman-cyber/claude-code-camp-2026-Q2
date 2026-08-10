require_relative "../helper"
require "tmpdir"
require "json"
require "mud_monitor/error_log_store"

module MudMonitor
  class ErrorLogStoreTest < Minitest::Test
    def test_disabled_when_file_missing
      store = ErrorLogStore.new(File.join(Dir.mktmpdir, "nope.log"))
      refute store.enabled?
      assert_empty store.recent
    end

    def test_reads_newest_first
      Dir.mktmpdir do |dir|
        path = File.join(dir, "error.log")
        File.write(path, [
          { at: "2026-08-01T00:00:00Z", error_class: "RuntimeError", message: "first", backtrace: [] }.to_json,
          { at: "2026-08-01T00:00:01Z", error_class: "ArgumentError", message: "second", backtrace: ["a.rb:1"] }
        ].map(&:to_json).join("\n"))

        entries = ErrorLogStore.new(path).recent
        assert_equal 2, entries.length
        assert_equal "second", entries.first.message # newest first
        assert_equal ["a.rb:1"], entries.first.backtrace
      end
    end
  end
end
