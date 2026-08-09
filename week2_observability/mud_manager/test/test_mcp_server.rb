require_relative "helper"
require "stringio"
require "json"
require "mud_manager/mcp/server"

# Drives MudManager::Mcp::Server directly over in-memory pipes (no
# subprocess), against a real FakeMud. This is the fast, in-process layer of
# the daemon's protocol coverage; test_mcp_client_e2e.rb covers the real
# subprocess path.
class TestMcpServer < Minitest::Test
  include DaemonTestHelper

  def setup
    @fake = start_fake_mud
  end

  def teardown
    @fake&.stop
  end

  def responses_for(messages)
    input  = StringIO.new(messages.map { |m| JSON.generate(m) }.join("\n") + "\n")
    output = StringIO.new
    pool = MudManager::Mcp::SessionPool.new(
      MudManager::Mcp::Config.new(host: "127.0.0.1", port: @fake.port, name: "Gandalf",
                                   password: "secret", timeout: 10.0)
    )
    MudManager::Mcp::Server.new(input: input, output: output, session_pool: pool).run
    output.string.each_line.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  end

  def rpc(id, method, params = {})
    { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  end

  def test_initialize_reports_server_info
    res = responses_for([rpc(1, "initialize")])
    assert_equal "mud-manager", res[0]["result"]["serverInfo"]["name"]
    refute_nil res[0]["result"]["serverInfo"]["version"]
  end

  def test_tools_list_returns_all_tools_with_schemas
    res = responses_for([rpc(1, "tools/list")])
    tools = res[0]["result"]["tools"]
    assert_equal 27, tools.size
    assert tools.all? { |t| t.key?("inputSchema") }
    assert_includes tools.map { |t| t["name"] }, "look"
  end

  def test_tools_call_reaches_the_mud
    res = responses_for([rpc(1, "tools/call", { "name" => "look", "arguments" => {} })])
    result = res[0]["result"]
    refute result["isError"]
    assert_match(/You do: look/, result["content"][0]["text"])
  end

  # inspect is look + exits composed into one call — proves both commands
  # actually reach the (fake) MUD and come back labelled.
  def test_tools_call_inspect_combines_look_and_exits
    res = responses_for([rpc(1, "tools/call", { "name" => "inspect", "arguments" => {} })])
    result = res[0]["result"]
    refute result["isError"]
    text = result["content"][0]["text"]
    assert_match(/== look ==\s*You do: look/, text)
    assert_match(/== exits ==\s*You do: exits/, text)
  end

  def test_tools_call_error_comes_back_as_data
    res = responses_for([rpc(1, "tools/call", { "name" => "move", "arguments" => { "direction" => "sideways" } })])
    result = res[0]["result"]
    assert result["isError"]
    assert_match(/argument_error/, result["content"][0]["text"])
  end

  def test_notifications_get_no_response
    res = responses_for([{ "jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => {} }])
    assert_empty res
  end

  def test_unknown_method_with_id_returns_json_rpc_error
    res = responses_for([rpc(1, "no/such/method")])
    refute_nil res[0]["error"]
  end
end
