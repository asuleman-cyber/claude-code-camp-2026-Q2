require_relative "../session"
require_relative "config"

module MudManager
  module Mcp
    # Owns the single MudManager::Session this daemon process manages, and
    # hides connect/login behind the tool boundary: the LLM only ever sees
    # gameplay tools. Credentials come from the process environment, never
    # from tool arguments. On a dropped socket, the next call transparently
    # reconnects and re-logs-in.
    class SessionPool
      def initialize(config = Config.from_env)
        @config  = config
        @session = nil
        @mutex   = Mutex.new
      end

      def ensure_connected!
        @mutex.synchronize do
          @session = nil if @session && !@session.open?
          @session ||= connect_and_login
        end
      end

      # Non-connecting read: for tools (poll, mud_status) that must not force
      # a connect just to answer "is there a session right now?".
      def connected_session
        @session if @session&.open?
      end

      def status_text
        if connected_session
          "connected to #{@config.host}:#{@config.port} as #{@config.name}"
        else
          "not connected"
        end
      end

      private

      def connect_and_login
        raise ArgumentError, "MUD_NAME is required"     if blank?(@config.name)
        raise ArgumentError, "MUD_PASSWORD is required"  if blank?(@config.password)

        session = MudManager::Session.new(host: @config.host, port: @config.port, timeout: @config.timeout)
        session.open
        session.login(@config.name, @config.password)
        session
      end

      def blank?(v) = v.nil? || v.to_s.strip.empty?
    end
  end
end
