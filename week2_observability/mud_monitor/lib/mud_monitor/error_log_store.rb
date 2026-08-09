require "json"

module MudMonitor
  # Reads the agent's error log (Boukensha::ErrorLog, Phase F) — a single
  # (not date-rotated — errors are rare enough not to need it) JSONL file,
  # newest first.
  ErrorEntry = Struct.new(:at, :context, :error_class, :message, :backtrace, keyword_init: true)

  class ErrorLogStore
    def initialize(path)
      @path = path
    end

    def enabled?
      @path && File.exist?(@path)
    end

    def recent(limit: 200)
      return [] unless enabled?

      File.readlines(@path).last(limit).filter_map { |l| parse_line(l) }.reverse
    end

    private

    def parse_line(line)
      line = line.strip
      return nil if line.empty?

      data = JSON.parse(line)
      ErrorEntry.new(at: data["at"], context: data["context"], error_class: data["error_class"],
                      message: data["message"], backtrace: data["backtrace"] || [])
    rescue JSON::ParserError
      nil
    end
  end
end
