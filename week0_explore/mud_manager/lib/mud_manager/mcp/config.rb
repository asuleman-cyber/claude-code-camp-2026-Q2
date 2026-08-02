require_relative "../session"

module MudManager
  module Mcp
    # Connection config for the daemon's single implicit session. Credentials
    # come from the process environment only — never from tool arguments —
    # exactly like live_session_test.rb already does.
    Config = Struct.new(:host, :port, :name, :password, :timeout, keyword_init: true) do
      def self.from_env(env = ENV)
        new(
          host:     env["MUD_HOST"] || MudManager::Session::DEFAULT_HOST,
          port:     Integer(env["MUD_PORT"] || MudManager::Session::DEFAULT_PORT),
          name:     env["MUD_NAME"],
          password: env["MUD_PASSWORD"],
          timeout:  Float(env["MUD_TIMEOUT"] || MudManager::Session::DEFAULT_TIMEOUT)
        )
      end
    end
  end
end
