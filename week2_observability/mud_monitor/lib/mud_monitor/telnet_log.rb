require "json"

module MudMonitor
  # Reads the telnet log mud_manager writes (MudManager::TelnetLog) — daily-
  # rotated JSONL, one record per chunk in either direction. This is the read
  # side; mud_manager owns writing (including password redaction).
  TelnetEntry = Struct.new(:seq, :at, :mono_ms, :session, :dir, :text, :bytes,
                           :redacted, :file, keyword_init: true)

  class TelnetLogStore
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

    def recent(date: nil, limit: 300)
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
      TelnetEntry.new(
        seq: data["seq"], at: data["at"], mono_ms: data["mono_ms"],
        session: data["session"], dir: data["dir"], text: data["text"],
        bytes: data["bytes"], redacted: data["redacted"], file: File.basename(path)
      )
    rescue JSON::ParserError
      nil
    end
  end
end
