require "json"

module MudMonitor
  # Reads the manager log mud_manager writes (MudManager::ManagerLog) —
  # daily-rotated JSONL, one record per tool call the daemon executed. This
  # is the read side; mud_manager owns writing.
  ManagerEntry = Struct.new(:seq, :at, :mono_ms, :session, :mode, :tool, :args,
                            :sent, :received, :elapsed_ms, :error, :file,
                            keyword_init: true)

  class ManagerLogStore
    LIVE_WINDOW_SECONDS = 15

    def initialize(dir)
      @dir = dir
    end

    def enabled?
      @dir && Dir.exist?(@dir)
    end

    def dates
      return [] unless enabled?

      Dir.glob(File.join(@dir, "*.jsonl")).map { |f| File.basename(f, ".jsonl") }.sort.reverse
    end

    # Most recent `limit` entries across the given date (default: latest
    # date with data), oldest-first so a table/feed reads top-to-bottom in
    # chronological order.
    def recent(date: nil, limit: 200)
      return [] unless enabled?

      date ||= dates.first
      return [] unless date

      path = File.join(@dir, "#{date}.jsonl")
      return [] unless File.exist?(path)

      lines = File.readlines(path)
      lines.last(limit).filter_map { |l| parse_line(l, path) }
    end

    def live?(date: nil)
      return false unless enabled?

      date ||= dates.first
      return false unless date

      path = File.join(@dir, "#{date}.jsonl")
      File.exist?(path) && (Time.now - File.mtime(path)) <= LIVE_WINDOW_SECONDS
    end

    private

    def parse_line(line, path)
      line = line.strip
      return nil if line.empty?

      data = JSON.parse(line)
      ManagerEntry.new(
        seq: data["seq"], at: data["at"], mono_ms: data["mono_ms"],
        session: data["session"], mode: data["mode"], tool: data["tool"],
        args: data["args"], sent: data["sent"], received: data["received"],
        elapsed_ms: data["elapsed_ms"], error: data["error"], file: File.basename(path)
      )
    rescue JSON::ParserError
      nil
    end
  end
end
