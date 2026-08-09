require_relative "jsonl_appender"

module MudManager
  # Records every tool call the daemon's Dispatcher executes and what it
  # returned upward — the "what mud_manager actually did" layer, one level
  # above the raw telnet bytes (TelnetLog). One record per Dispatcher#call,
  # success or failure, with its elapsed time.
  #
  # Off by default, independently of TelnetLog — enabled by setting
  # MUD_MANAGER_LOG_DIR. This is the cheap, always-on-able log; telnet is the
  # expensive one.
  class ManagerLog
    def self.from_env
      dir = ENV["MUD_MANAGER_LOG_DIR"]
      dir && !dir.strip.empty? ? new(dir: dir) : nil
    end

    def initialize(dir:)
      @appender = JsonlAppender.new(dir)
    end

    # mode is the tool's dispatch kind ("command" | "raw" | "poll" | "status"
    # | "inspect"). tool/args identify the MCP call; sent/received carry
    # whatever text is meaningful for that mode (nil where there isn't a
    # single outgoing/incoming string, e.g. poll's "whatever was buffered").
    def exchange(session:, mode:, tool: nil, args: nil, sent: nil, received: nil, elapsed_ms: nil, error: nil)
      @appender.write(
        session:    session,
        mode:       mode,
        tool:       tool,
        args:       args,
        sent:       sent,
        received:   received,
        elapsed_ms: elapsed_ms,
        error:      error
      )
    end
  end
end
