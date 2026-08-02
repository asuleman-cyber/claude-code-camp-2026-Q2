require_relative "helper"

# A real MudManager::Mcp::Client spawns the real bin/mud-manager subprocess
# against a real (fake) MUD over TCP — the full stdio round trip, no shortcuts.
class TestMcpClientE2E < Minitest::Test
  include DaemonTestHelper

  def setup
    @fake = start_fake_mud
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  def test_handshake_discovery_and_dispatch_over_a_real_subprocess
    @client = spawn_daemon(fake_mud_env(@fake))

    assert_equal "mud-manager", @client.server_info["name"]
    assert_equal 26, @client.tools.size
    assert_includes @client.tools.map { |t| t["name"] }, "attack"

    result = @client.call_tool("look")
    refute result[:error]
    assert_match(/You do: look/, result[:text])

    result = @client.call_tool("attack", "target" => "dragon")
    refute result[:error]
    assert_match(/You do: kill dragon/, result[:text])
  end

  def test_send_raw_bypasses_primitives
    @client = spawn_daemon(fake_mud_env(@fake))
    result = @client.call_tool("send_raw", "raw" => "score")
    refute result[:error]
    assert_match(/You do: score/, result[:text])
  end

  def test_poll_does_not_force_a_connection
    @client = spawn_daemon(fake_mud_env(@fake))
    result = @client.call_tool("poll")
    refute result[:error]
    assert_equal "", result[:text]
  end

  def test_mud_status_before_and_after_connecting
    @client = spawn_daemon(fake_mud_env(@fake))
    before = @client.call_tool("mud_status")
    assert_match(/not connected/, before[:text])

    @client.call_tool("look")
    after = @client.call_tool("mud_status")
    assert_match(/connected to/, after[:text])
  end

  def test_spawning_a_nonexistent_command_raises
    assert_raises(Errno::ENOENT) do
      MudManager::Mcp::Client.spawn(command: "boukensha-no-such-mcp-server-xyz")
    end
  end
end
