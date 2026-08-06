# BoukenshaLoader resolves which step folder and config directory to use, then
# boots the REPL.
#
# Each setting is resolved independently in this order:
#   1. BOUKENSHA_PATH / BOUKENSHA_DIR environment variable
#   2. boukensha_path / boukensha_dir in ~/.boukensharc
#   3. The bundled lib / ~/.boukensha default
#
# ~/.boukensharc is YAML:
#   boukensha_path: ~/Sites/boukensha/09_global_executable
#   boukensha_dir: ~/projects/mybot/.boukensha
# A bare single-line path (the pre-step-9 format) is still accepted and is
# treated as boukensha_path.
#
# MUD (and any other tool) connection details come from settings.yaml's
# `mcp_servers:` block. A spawned server inherits this process's environment,
# so a legacy var like MUD_HOST still reaches it — but only for keys the
# server's own `env:` block doesn't already set; config wins over the
# environment.
#
# --no-tui falls back to the plain terminal REPL (no charm-ruby).
#
# Examples:
#   boukensha                                                              # uses bundled lib + ~/.boukensha
#   BOUKENSHA_PATH=~/Sites/boukensha/04_api_client boukensha              # loads step 4
#   BOUKENSHA_DIR=~/projects/mybot/.boukensha boukensha                   # custom config dir
#   boukensha --no-tui                                                     # plain REPL, no TUI
require "yaml"

module BoukenshaLoader
  # Absolute path to this gem's own bundled boukensha lib.
  BUNDLED_LIB = File.expand_path("../boukensha.rb", __FILE__)

  def self.rc_file
    File.expand_path("~/.boukensharc")
  end

  def self.load_rc
    return {} unless File.exist?(rc_file)

    parsed = YAML.safe_load(
      File.read(rc_file),
      permitted_classes: [],
      aliases: false
    )

    case parsed
    when Hash
      parsed
    when String
      # Backward compatibility with the original single-path format.
      { "boukensha_path" => parsed }
    when nil
      {}
    else
      abort "boukensha: #{rc_file} must contain a YAML mapping"
    end
  rescue Psych::SyntaxError => e
    abort "boukensha: invalid YAML in #{rc_file}: #{e.message}"
  end

  def self.expand_rc_path(path)
    return nil unless path.is_a?(String)
    return nil if path.strip.empty?

    File.expand_path(path, File.dirname(rc_file))
  end

  def self.resolve
    rc = load_rc

    # Apply this before requiring the selected implementation. An explicit
    # environment variable always wins over the rc file.
    rc_config_dir = expand_rc_path(rc["boukensha_dir"])
    ENV["BOUKENSHA_DIR"] = rc_config_dir if !ENV["BOUKENSHA_DIR"] && rc_config_dir

    source = ENV["BOUKENSHA_PATH"] || expand_rc_path(rc["boukensha_path"])
    return BUNDLED_LIB unless source

    dir = File.expand_path(source)
    main = File.join(dir, "lib", "boukensha.rb")
    return main if File.exist?(main)

    abort <<~MSG
      boukensha: no lib/boukensha.rb found at:
             #{dir}
             Check BOUKENSHA_PATH or #{rc_file}.
    MSG
  end

  def self.load_and_start_repl
    main = resolve
    step_dir = File.dirname(File.dirname(main))

    puts "[boukensha] loading from: #{step_dir}" if ENV["BOUKENSHA_DEBUG"]

    require main

    unless Boukensha.respond_to?(:repl)
      abort <<~MSG
        boukensha: the step at #{step_dir}
               does not support the interactive REPL (added in step 7).
               Run its examples directly, e.g.:
                 ruby #{step_dir}/examples/*.rb
               Or point BOUKENSHA_PATH at step 7 or later.
      MSG
    end

    # --no-tui falls back to the plain terminal REPL (no charm-ruby).
    no_tui = ARGV.delete("--no-tui")

    # Nothing else to pass: the agent's tools all come from settings.yaml's
    # `mcp_servers:` block, so there is no MUD — or any other tool — to
    # configure here.
    #
    # Note this drops the old MUD_* env override. A spawned server inherits
    # this process's environment, so exporting MUD_HOST still reaches the
    # daemon, but only for keys its `env:` block doesn't set: config now wins
    # over the environment, where it used to lose.
    #
    # Mud::Hooks (Phase D — docs/plans/week2_catchup_plan.md): wired here,
    # not shipped by boukensha itself. Phase C's `inspect_room` native tool
    # is GONE — the player has no room tool any more. Position is
    # established automatically every model iteration (before_model),
    # persisted to knowledge.sqlite3, and pushed to the model as a compact
    # state block instead of a tool result (see Mud::StateBlock). MUD calls
    # still go through `dispatch` (RunDSL#dispatch), so they're gated by
    # the same Registry/`allow:` as every other tool (Phase A). Wired only
    # if a `mud` MCP server is actually configured, and only if the
    # sqlite3 gem is installed — a checkout without it still boots, just
    # without memory (matching the source plan's posture for its own
    # optional dependency).
    mud_prefix = Boukensha.config.mcp_servers["mud"]&.[](:prefix)
    Boukensha.repl(tui: !no_tui) do
      if mud_prefix
        begin
          require "boukensha/mud/memory/store"
          require "boukensha/mud/memory/journal"
          require "boukensha/mud/hooks"

          # Change capture (Phase E) — a time series alongside the snapshot,
          # off by default (MUD_JOURNAL_DIR). See Memory::Journal's own doc.
          journal = Boukensha::Mud::Memory::Journal.from_env
          db_path = File.join(Boukensha.config.dir, "knowledge.sqlite3")
          store   = Boukensha::Mud::Memory::Store.open(db_path, journal: journal)
          mud_tool_name = ->(name) { [mud_prefix, name].reject(&:empty?).join("__") }

          self.hooks = Boukensha::Mud::Hooks.new(
            call_tool: ->(name, args) { dispatch(mud_tool_name.call(name), args) },
            store: store,
            error_log: Boukensha::ErrorLog.from_env
          )
          at_exit { store.close rescue nil }
        rescue LoadError
          warn "[boukensha] sqlite3 gem not installed — running without room memory (Phase D). " \
               "`gem install sqlite3` to enable it."
        end
      end
    end
  end
end
