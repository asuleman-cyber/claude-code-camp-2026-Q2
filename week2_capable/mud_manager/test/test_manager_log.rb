require_relative "helper"
require "tmpdir"
require "json"

class TestManagerLog < Minitest::Test
  def test_from_env_is_nil_when_unset
    with_env("MUD_MANAGER_LOG_DIR" => nil) do
      assert_nil MudManager::ManagerLog.from_env
    end
  end

  def test_exchange_writes_one_jsonl_record_per_call
    Dir.mktmpdir do |dir|
      log = MudManager::ManagerLog.new(dir: dir)
      log.exchange(session: "default", mode: "command", tool: "look", args: {},
                   received: "The Common Square", elapsed_ms: 42, error: nil)

      record = read_records(dir).first
      assert_equal "command", record["mode"]
      assert_equal "look", record["tool"]
      assert_equal "The Common Square", record["received"]
      assert_equal 42, record["elapsed_ms"]
      assert_nil record["error"]
      refute_nil record["at"]
      refute_nil record["mono_ms"]
    end
  end

  def test_seq_increments_across_calls
    Dir.mktmpdir do |dir|
      log = MudManager::ManagerLog.new(dir: dir)
      3.times { |i| log.exchange(session: "default", mode: "command", tool: "look#{i}") }

      records = read_records(dir)
      assert_equal [0, 1, 2], records.map { |r| r["seq"] }
    end
  end

  def test_dispatcher_logs_every_call_when_a_manager_log_is_configured
    fake = MudManager::FakeMud.new
    Dir.mktmpdir do |dir|
      log = MudManager::ManagerLog.new(dir: dir)
      pool = MudManager::Mcp::SessionPool.new(
        MudManager::Mcp::Config.new(host: "127.0.0.1", port: fake.port, name: "Gandalf",
                                     password: "secret", timeout: 10.0)
      )
      dispatcher = MudManager::Mcp::Dispatcher.new(pool, manager_log: log)

      result = dispatcher.call("look", {})
      refute result[:error]

      record = read_records(dir).first
      assert_equal "look", record["tool"]
      assert_equal "command", record["mode"]
      assert_match(/You do: look/, record["received"])
      assert record["elapsed_ms"] >= 0
      assert_nil record["error"]
    end
  ensure
    fake&.stop
  end

  def test_dispatcher_logs_argument_errors_too
    fake = MudManager::FakeMud.new
    Dir.mktmpdir do |dir|
      log = MudManager::ManagerLog.new(dir: dir)
      pool = MudManager::Mcp::SessionPool.new(
        MudManager::Mcp::Config.new(host: "127.0.0.1", port: fake.port, name: "Gandalf",
                                     password: "secret", timeout: 10.0)
      )
      dispatcher = MudManager::Mcp::Dispatcher.new(pool, manager_log: log)

      result = dispatcher.call("move", { "direction" => "sideways" })
      assert result[:error]

      record = read_records(dir).first
      assert_equal "move", record["tool"]
      refute_nil record["error"]
    end
  ensure
    fake&.stop
  end

  def test_dispatcher_works_unchanged_with_no_manager_log
    fake = MudManager::FakeMud.new
    pool = MudManager::Mcp::SessionPool.new(
      MudManager::Mcp::Config.new(host: "127.0.0.1", port: fake.port, name: "Gandalf",
                                   password: "secret", timeout: 10.0)
    )
    dispatcher = MudManager::Mcp::Dispatcher.new(pool, manager_log: nil)
    result = dispatcher.call("look", {})
    refute result[:error]
  ensure
    fake&.stop
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
