require "json"
require "fileutils"
require "time"

module Boukensha
  module Mud
    module Memory
      # Append-only JSONL "what changed, in order" log — per
      # docs/plans/week_2/change_capture.md. knowledge.sqlite3 (Store) is a
      # snapshot of current belief; it can say the agent is level 5, not
      # *when* it hit level 5. This is a fourth log alongside sessions/,
      # manager/, and telnet/ (Phase B) — same daily-rotated JSONL idiom,
      # read by mud_monitor the same way. Off by default (MUD_JOURNAL_DIR).
      #
      # #upsert is the whole idea: callers always hand it the CURRENT
      # reading, every time, and never track "did this change" themselves —
      # the journal compares against the last value it saw for
      # [stream, key] (in-process) and writes a line only on an actual
      # transition. No-ops (the common case for hp/mana/move on most tool
      # calls) write nothing.
      #
      # Scope note (see this gem's report doc): only Store's player_state
      # writes and new-room discovery are journaled in this build — not
      # entity discovery, not items/skills (those tables don't exist yet;
      # see the deferred player_update.md scope). The mechanism is generic
      # and ready for more callers whenever that lands.
      class Journal
        def self.from_env
          dir = ENV["MUD_JOURNAL_DIR"]
          dir && !dir.strip.empty? ? new(dir) : nil
        end

        def initialize(dir)
          @dir   = dir
          FileUtils.mkdir_p(@dir)
          @last  = {}
          @mutex = Mutex.new
          @seq   = 0
        end

        # Returns true if it wrote (value differed from the last one seen
        # for this [stream, key] this process). meta is arbitrary
        # additional fields (e.g. room_id) merged into the record.
        def upsert(stream:, key:, value:, **meta)
          cache_key = [stream, key]
          @mutex.synchronize do
            return false if @last.key?(cache_key) && @last[cache_key] == value

            from = @last[cache_key]
            @last[cache_key] = value
            write(stream: stream, key: key, from: from, to: value, **meta)
          end
          true
        end

        # The escape hatch for discrete events that aren't a keyed-value
        # transition (a room discovered, an item picked up).
        def event(stream:, op:, **meta)
          @mutex.synchronize { write(stream: stream, op: op, **meta) }
        end

        private

        def write(**fields)
          path = File.join(@dir, "#{Time.now.strftime("%Y%m%d")}.jsonl")
          @seq += 1
          File.open(path, "a") do |io|
            io.puts(JSON.generate(fields.merge(seq: @seq, at: Time.now.iso8601(3))))
          end
        end
      end
    end
  end
end
