require "json"
require "fileutils"
require "time"

module Boukensha
  # Cross-session memory for one character: what it learned, got wrong, and
  # left unfinished — carried from one run to the next.
  #
  # This is deliberately NOT knowledge.sqlite3. That store holds *spatial*
  # truth — rooms, exits, what stands where — and answers "what is there?".
  # This holds *narrative* truth — "the pit fiend killed me at level 3",
  # "shopkeepers won't buy corpses" — and answers "what have I learned?".
  # Trying to put the second kind in a room graph is how you end up with a
  # schema of loose ends nothing can query.
  #
  # Two files per character, both under <config>/memory/:
  #
  #   <name>.jsonl — append-only raw records, one per event. The permanent
  #                  history; nothing ever rewrites it.
  #   <name>.md    — a bounded prose digest, rewritten wholesale by the
  #                  Chronicler. The part that is actually read back.
  #
  # The split matters: the digest is what a Planner can afford to read every
  # session, and it stays small because it is *rewritten*, not appended to. A
  # memory that only grows is a memory that eventually costs more than it is
  # worth. The jsonl is the audit trail behind it, read only by the
  # Chronicler.
  #
  # Every write is open-append-close. Holding a handle open across writes is
  # a documented real bug in this project (Phase B's logger, caught in Phase
  # D): on Windows a handle held open by one process blocks another from
  # deleting the file, which broke Dir.mktmpdir cleanup in tests. Don't
  # reintroduce it here.
  class PlayerMemory
    DIR_NAME = "memory".freeze

    # How much digest a Planner is willing to read. Past this the Chronicler
    # is told to cut, and the file is truncated defensively on write —
    # unbounded memory injected into every planning call is a slow leak in
    # both cost and attention.
    MAX_DIGEST_CHARS = 4_000

    # How many raw records the Chronicler is shown when redistilling.
    DISTILL_RECORDS = 60

    HEADINGS = ["Discoveries", "Mistakes", "Strategies", "Open threads"].freeze

    attr_reader :name, :dir

    # nil when memory is off or there is no character name to file it under —
    # callers treat nil as "no memory", exactly as they treat a missing
    # knowledge store.
    def self.build(config:, name:, enabled: false)
      return nil unless enabled

      safe = sanitize(name)
      return nil if safe.nil?

      new(dir: File.join(config.dir, DIR_NAME), name: safe)
    end

    # The name becomes a filename, so it is whitelisted rather than escaped:
    # a MUD character name is letters, digits, and the odd dash or
    # underscore, and anything else is likelier a mistake (or a traversal
    # attempt through a settings.yaml) than a real character.
    def self.sanitize(name)
      cleaned = name.to_s.strip.gsub(/[^A-Za-z0-9_-]/, "")
      cleaned.empty? ? nil : cleaned
    end

    def initialize(dir:, name:)
      @dir  = dir
      @name = name
      FileUtils.mkdir_p(@dir)
    end

    def jsonl_path  = File.join(@dir, "#{@name}.jsonl")
    def digest_path = File.join(@dir, "#{@name}.md")

    # Append one raw record. Never rewrites; never reads the file first.
    def record(kind:, **fields)
      write_line(kind: kind.to_s, **fields)
      true
    rescue StandardError
      # Memory failing must never take down a turn — same posture as
      # Mud::Hooks and the knowledge tool.
      false
    end

    # The prose digest, or nil if this character has none yet.
    def digest
      return nil unless File.exist?(digest_path)

      text = File.read(digest_path).strip
      text.empty? ? nil : text
    rescue StandardError
      nil
    end

    # Replace the digest wholesale. Truncated at MAX_DIGEST_CHARS on a line
    # boundary so a Chronicler that ignored its length budget can't quietly
    # inflate every future planning call.
    def write_digest(text)
      body = truncate(text.to_s.strip)
      return false if body.empty?

      File.write(digest_path, "#{body}\n")
      record(kind: "digest_written", chars: body.length)
      true
    rescue StandardError
      false
    end

    # The most recent raw records, oldest first — what the Chronicler
    # distils. Reads the tail rather than the whole file, so a long-lived
    # character doesn't make redistilling progressively more expensive.
    def recent_records(limit: DISTILL_RECORDS)
      return [] unless File.exist?(jsonl_path)

      File.readlines(jsonl_path).last(limit).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil # a torn final line from a killed process is not a reason to fail
      end
    rescue StandardError
      []
    end

    def empty?
      digest.nil? && recent_records(limit: 1).empty?
    end

    private

    def write_line(**fields)
      File.open(jsonl_path, "a") do |io|
        io.puts(JSON.generate(fields.merge(name: @name, at: Time.now.iso8601(3))))
      end
    end

    def truncate(body)
      return body if body.length <= MAX_DIGEST_CHARS

      kept = body[0, MAX_DIGEST_CHARS]
      cut  = kept.rindex("\n") || MAX_DIGEST_CHARS
      "#{kept[0, cut].rstrip}\n\n_(truncated)_"
    end
  end
end
