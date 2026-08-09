require "json"

module MudMonitor
  # Reads the change-capture journal (Boukensha::Mud::Memory::Journal,
  # Phase E) — daily-rotated JSONL, one record per actual change (upserts)
  # or discrete event. Same read-a-fresh-copy-per-call shape as
  # ManagerLogStore/TelnetLogStore (Phase B).
  JournalEntry = Struct.new(:seq, :at, :stream, :key, :from, :to, :op, :extra, keyword_init: true)

  class JournalStore
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

      File.readlines(path).last(limit).filter_map { |l| parse_line(l) }
    end

    private

    def parse_line(line)
      line = line.strip
      return nil if line.empty?

      data = JSON.parse(line)
      known = %w[seq at stream key from to op]
      JournalEntry.new(
        seq: data["seq"], at: data["at"], stream: data["stream"], key: data["key"],
        from: data["from"], to: data["to"], op: data["op"],
        extra: data.reject { |k, _| known.include?(k) }
      )
    rescue JSON::ParserError
      nil
    end
  end
end
