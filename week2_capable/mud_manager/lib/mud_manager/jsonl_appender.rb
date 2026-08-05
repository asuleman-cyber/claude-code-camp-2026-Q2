require "json"
require "fileutils"
require "time"

module MudManager
  # Shared plumbing for the daily-rotated JSONL logs (TelnetLog, ManagerLog):
  # a monotonically increasing `seq` per file (seeded from the file's current
  # line count, so a process restart mid-day doesn't collide with what's
  # already on disk), one writer lock per file set — because the telnet log
  # in particular is written from two different threads (the socket reader
  # for inbound, the caller's thread for outbound), a lock is load-bearing
  # here, not a formality.
  #
  # Each write opens, appends, and closes the file rather than holding a
  # handle open: at these volumes (a teaching MUD, not production traffic)
  # the extra open/close is free, and not holding a handle open means a
  # process that never explicitly closes this (the common case — it lives
  # for the daemon's lifetime) never leaves a file locked open, which
  # matters concretely on Windows, where an open handle blocks the file
  # (and its containing temp dir) from being deleted.
  class JsonlAppender
    def initialize(dir)
      @dir   = dir
      FileUtils.mkdir_p(@dir)
      @mutex = Mutex.new
      @seqs  = {}
    end

    # fields merges with seq/at/mono_ms and is written as one JSON line.
    def write(fields)
      @mutex.synchronize do
        path = File.join(@dir, "#{Time.now.strftime("%Y%m%d")}.jsonl")
        @seqs[path] ||= (File.exist?(path) ? File.foreach(path).count : 0)
        seq = @seqs[path]
        @seqs[path] += 1

        File.open(path, "a") do |io|
          io.puts(JSON.generate(fields.merge(
            seq: seq, at: Time.now.iso8601(3),
            mono_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
          )))
        end
      end
    end
  end
end
