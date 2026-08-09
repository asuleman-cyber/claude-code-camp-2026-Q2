require_relative "helper"
require "tmpdir"
require "json"

class TestTelnetLog < Minitest::Test
  def test_from_env_is_nil_when_unset
    with_env("MUD_TELNET_LOG_DIR" => nil) do
      assert_nil MudManager::TelnetLog.from_env
    end
  end

  def test_from_env_is_nil_when_blank
    with_env("MUD_TELNET_LOG_DIR" => "  ") do
      assert_nil MudManager::TelnetLog.from_env
    end
  end

  def test_from_env_builds_a_log_when_set
    Dir.mktmpdir do |dir|
      with_env("MUD_TELNET_LOG_DIR" => dir) do
        refute_nil MudManager::TelnetLog.from_env
      end
    end
  end

  def test_chunk_writes_one_jsonl_record_per_call
    Dir.mktmpdir do |dir|
      log = MudManager::TelnetLog.new(dir: dir)
      log.chunk(session: "default", dir: "out", text: "look")
      log.chunk(session: "default", dir: "in", text: "The Common Square\r\n")

      records = read_records(dir)
      assert_equal 2, records.size
      assert_equal 0, records[0]["seq"]
      assert_equal 1, records[1]["seq"]
      assert_equal "out", records[0]["dir"]
      assert_equal "look", records[0]["text"]
      assert_equal 4, records[0]["bytes"]
      assert_equal "in", records[1]["dir"]
    end
  end

  def test_redacted_chunk_never_writes_the_real_text
    Dir.mktmpdir do |dir|
      log = MudManager::TelnetLog.new(dir: dir)
      log.chunk(session: "default", dir: "out", text: "super-secret-password", redacted: true)

      raw = File.read(Dir.glob(File.join(dir, "*.jsonl")).first)
      refute_match(/super-secret-password/, raw)

      record = read_records(dir).first
      assert record["redacted"]
      assert_equal "<redacted>", record["text"]
      assert_equal "super-secret-password".bytesize, record["bytes"]
    end
  end

  def test_session_wires_a_telnet_log_and_redacts_the_password
    Dir.mktmpdir do |dir|
      fake = MudManager::FakeMud.new(password: "secret")
      log  = MudManager::TelnetLog.new(dir: dir)
      session = MudManager::Session.new(host: "127.0.0.1", port: fake.port, telnet_log: log)
      session.open
      session.login("Gandalf", "secret")
      session.close

      raw = Dir.glob(File.join(dir, "*.jsonl")).map { |f| File.read(f) }.join
      refute_match(/secret/, raw)

      records = read_records(dir)
      redacted = records.select { |r| r["redacted"] }
      refute_empty redacted
      assert_equal "<redacted>", redacted.first["text"]
    ensure
      fake&.stop
    end
  end

  private

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def read_records(dir)
    Dir.glob(File.join(dir, "*.jsonl")).sort.flat_map do |f|
      File.readlines(f).map { |l| JSON.parse(l) }
    end
  end
end
