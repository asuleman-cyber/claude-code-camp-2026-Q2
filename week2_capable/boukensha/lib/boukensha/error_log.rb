require "json"
require "fileutils"
require "time"

module Boukensha
  # Captures exceptions with their backtraces to a JSONL log, surfaced in
  # mud_monitor (Phase F — docs/plans/week_2/error_log.md, scoped down —
  # see this gem's report doc). One line per error: class, message,
  # backtrace, and a free-form `context` string identifying where it was
  # caught, so "what broke and where" survives even when the surrounding
  # code degrades silently rather than crashing (Mud::Hooks' own rescue
  # clauses used to just swallow everything — this is what they log to
  # now).
  #
  # Off by default via `from_env`, matching every other optional log in
  # this project (manager/telnet — Phase B).
  class ErrorLog
    def self.from_env
      path = ENV["BOUKENSHA_ERROR_LOG"]
      path && !path.strip.empty? ? new(path) : nil
    end

    def initialize(path)
      @path = path
    end

    def record(error, context: nil)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a") do |io|
        io.puts(JSON.generate(
          at: Time.now.iso8601(3),
          context: context,
          error_class: error.class.name,
          message: error.message,
          backtrace: (error.backtrace || []).first(20)
        ))
      end
    rescue StandardError
      nil # logging the error must never itself raise
    end
  end
end
