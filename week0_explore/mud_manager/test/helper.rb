require "minitest/autorun"
require "rbconfig"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "mud_manager"
require "mud_manager/fake_mud"
require "mud_manager/mcp/client"

MUD_MANAGER_BIN = File.expand_path("../bin/mud-manager", __dir__)

module DaemonTestHelper
  def start_fake_mud
    MudManager::FakeMud.new
  end

  def fake_mud_env(fake)
    {
      "MUD_HOST" => "127.0.0.1", "MUD_PORT" => fake.port.to_s,
      "MUD_NAME" => "Gandalf",   "MUD_PASSWORD" => "secret"
    }
  end

  def spawn_daemon(env)
    MudManager::Mcp::Client.spawn(command: RbConfig.ruby, args: [MUD_MANAGER_BIN, "--mcp"], env: env)
  end
end
