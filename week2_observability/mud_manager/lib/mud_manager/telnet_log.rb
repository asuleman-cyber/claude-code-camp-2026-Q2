require_relative "jsonl_appender"

module MudManager
  # Records every byte that crosses the telnet socket, in both directions —
  # the "what actually happened on the wire" layer, below the tool
  # abstraction. Written from MudManager::Session: the reader thread for
  # inbound chunks, #send_command for outbound. That is the one place every
  # byte passes in both directions, so it also captures the login dance the
  # dispatcher/pool layer never sees.
  #
  # Off by default — enabled by setting MUD_TELNET_LOG_DIR.
  class TelnetLog
    def self.from_env
      dir = ENV["MUD_TELNET_LOG_DIR"]
      dir && !dir.strip.empty? ? new(dir: dir) : nil
    end

    def initialize(dir:)
      @appender = JsonlAppender.new(dir)
    end

    # dir: "in" | "out". redacted: true writes a placeholder instead of
    # `text` — used for the password line in Session#login. The record still
    # shows that something was sent and its byte count, never what.
    def chunk(session:, dir:, text:, redacted: false)
      @appender.write(
        session:  session,
        dir:      dir,
        text:     redacted ? "<redacted>" : text,
        bytes:    text.to_s.bytesize,
        redacted: redacted
      )
    end
  end
end
