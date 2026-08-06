require_relative "helper"
require "tmpdir"
require "json"
require "boukensha/error_log"

class TestErrorLog < Minitest::Test
  def test_from_env_is_nil_when_unset
    old = ENV.delete("BOUKENSHA_ERROR_LOG")
    assert_nil Boukensha::ErrorLog.from_env
  ensure
    ENV["BOUKENSHA_ERROR_LOG"] = old if old
  end

  def test_record_writes_class_message_and_backtrace
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      log = Boukensha::ErrorLog.new(path)

      begin
        raise ArgumentError, "bad thing happened"
      rescue StandardError => e
        log.record(e, context: "somewhere")
      end

      record = JSON.parse(File.read(path))
      assert_equal "ArgumentError", record["error_class"]
      assert_equal "bad thing happened", record["message"]
      assert_equal "somewhere", record["context"]
      refute_empty record["backtrace"]
      refute_nil record["at"]
    end
  end

  def test_multiple_records_append
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      log = Boukensha::ErrorLog.new(path)
      log.record(RuntimeError.new("one"))
      log.record(RuntimeError.new("two"))

      lines = File.readlines(path)
      assert_equal 2, lines.length
    end
  end

  def test_record_never_raises_even_if_the_path_is_unwritable
    log = Boukensha::ErrorLog.new("Z:/does/not/exist/error.log")
    log.record(RuntimeError.new("boom")) # must not raise
  end
end
