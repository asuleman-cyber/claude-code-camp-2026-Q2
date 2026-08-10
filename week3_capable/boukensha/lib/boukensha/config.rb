require "yaml"
require "dotenv"
require "pathname"

module Boukensha
  class Config
    # The .boukensha config directory is resolved in this order:
    #   1. BOUKENSHA_DIR environment variable (set before loading .env)
    #   2. ~/.boukensha  (default)
    DEFAULT_DIR = File.join(Dir.home, ".boukensha").freeze

    # Default prompts shipped alongside this step (<gem root>/prompts).
    #
    # This was `../../../prompts` up to and including Week 2 — one `..` too
    # many, resolving to the gem root's *parent* (`week2_observability/prompts`,
    # `week1_baseline/ruby/prompts`), which has never existed in any step. So
    # the shipped `prompts/system.md` has never once been read: the live agent
    # works only because `.boukensha/settings.yaml` sets the player's
    # `prompt_override.system: true` and supplies its own
    # `.boukensha/prompts/player/system.md`.
    #
    # Phase G is what surfaced it — Planner and Judge have no user override to
    # be rescued by, so they booted with a nil system prompt. Fixing the path
    # makes the packaged defaults live for every task; the player's override
    # still wins over its default, exactly as before.
    PROMPTS_DIR = File.expand_path("../../prompts", __dir__).freeze

    attr_reader :dir, :settings

    def initialize
      @dir = resolve_dir
      load_env
      @settings = load_settings
    end

    # ---------- tasks -----------------------------------------------------

    # With no argument: returns the full tasks hash from settings.yaml.
    # With a name: returns that task's settings hash, e.g. tasks(:player).
    def tasks(name = nil)
      all = dig(:tasks) || {}
      name ? (all[name.to_s] || all[name.to_sym]) : all
    end

    # The user's prompts directory for task prompt overrides.
    def user_prompts_dir
      File.join(@dir, "prompts")
    end

    # ---------- provider --------------------------------------------------

    def provider_type
      dig(:tasks, :player, :provider) || "anthropic"
    end

    def model
      dig(:tasks, :player, :model) || "claude-haiku-4-5"
    end

    # ---------- MCP servers ------------------------------------------------

    # MCP servers to plug into the agent, keyed by name. This is where ALL of
    # the agent's tools come from — boukensha ships none of its own:
    #
    #   mcp_servers:
    #     mud:
    #       command: mud-manager
    #       args:    [--mcp]
    #       prefix:  tbamud
    #       env:
    #         MUD_HOST: your.mud.host      # a stdio server's credentials
    #         MUD_NAME: Gandalf            # travel by environment
    #
    # Returns { "mud" => { command:, args:, env:, prefix:, required: } } with
    # defaults applied. `required: false` lets a server fail to spawn without
    # taking the agent down with it.
    def mcp_servers
      (dig(:mcp_servers) || {}).each_with_object({}) do |(name, raw), out|
        entry = raw.is_a?(Hash) ? raw : {}
        get   = ->(k) { entry[k.to_s].nil? ? entry[k.to_sym] : entry[k.to_s] }
        req   = get.call(:required)

        out[name.to_s] = {
          command:  get.call(:command).to_s,
          args:     Array(get.call(:args)).map(&:to_s),
          env:      (get.call(:env) || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s },
          prefix:   get.call(:prefix)&.to_s,
          required: req.nil? ? true : !!req
        }
      end
    end

    # ---------- cross-session memory (Phase J) -----------------------------
    # Off by default — same "ship real, switch on deliberately" posture as
    # the compactor and Phase A's `allow:` engine:
    #
    #   memory:
    #     enabled: true

    def memory_enabled?
      env_boolean("BOUKENSHA_MEMORY_ENABLED", dig(:memory, :enabled), false)
    end

    # Which character the memory belongs to.
    #
    # Read from the `mud` MCP server's own `MUD_NAME` env entry — the same
    # value the daemon logs in with — rather than a separate setting, so the
    # memory file and the character on screen cannot drift apart. An explicit
    # `memory.character` wins if someone needs to override it.
    def character_name
      explicit = dig(:memory, :character)
      return explicit.to_s if explicit && !explicit.to_s.strip.empty?

      mcp_servers.dig("mud", :env, "MUD_NAME")
    end

    # ---------- agent limits ----------------------------------------------
    # Static per-turn circuit breakers, read where the agent is constructed.
    # A value of 0 or nil means "disabled" (no ceiling) — useful for debugging.

    def agent_max_iterations
      v = dig(:agent, :max_iterations)
      v.nil? ? 25 : Integer(v)
    end

    def agent_max_output_tokens
      v = dig(:agent, :max_output_tokens)
      v.nil? ? 1024 : Integer(v)
    end

    def agent_max_turn_tokens
      v = dig(:agent, :max_turn_tokens)
      v.nil? ? 60_000 : Integer(v)
    end

    def agent_compaction_threshold
      v = dig(:agent, :compaction_threshold)
      v.nil? ? 0.85 : Float(v)
    end

    # ---------- observability / OpenTelemetry ------------------------------
    # Off by default. A real process ENV var always wins over settings.yaml,
    # so deployments can override without editing (or committing secrets
    # into) the file:
    #
    #   observability:
    #     otel:
    #       enabled: true
    #       capture_content: false
    #       env:
    #         OTEL_SERVICE_NAME: boukensha
    #         OTEL_EXPORTER_OTLP_ENDPOINT: http://localhost:4318

    OTEL_ENV_NAME = /\AOTEL_[A-Z0-9_]+\z/.freeze

    def otel_enabled?
      env_boolean("BOUKENSHA_OTEL_ENABLED", dig(:observability, :otel, :enabled), false)
    end

    def otel_capture_content?
      env_boolean("BOUKENSHA_OTEL_CAPTURE_CONTENT", dig(:observability, :otel, :capture_content), false)
    end

    def otel_content_max_bytes
      raw   = ENV.fetch("BOUKENSHA_OTEL_CONTENT_MAX_BYTES", dig(:observability, :otel, :content_max_bytes) || 4096)
      value = Integer(raw)
      raise ArgumentError, "BOUKENSHA_OTEL_CONTENT_MAX_BYTES must be positive" unless value.positive?

      value
    end

    # Copies observability.otel.env's OTEL_* keys into the real process ENV
    # before the SDK configures (OpenTelemetry::SDK reads ENV directly at
    # configure-time). An existing ENV entry is never overwritten, so a real
    # deployment override always beats whatever settings.yaml says.
    def apply_otel_environment!
      configured = dig(:observability, :otel, :env) || {}
      raise ArgumentError, "observability.otel.env must be a YAML mapping" unless configured.is_a?(Hash)

      configured.each do |name, value|
        key = name.to_s
        unless OTEL_ENV_NAME.match?(key)
          raise ArgumentError, "observability.otel.env key #{key.inspect} must start with OTEL_ and use uppercase letters"
        end
        raise ArgumentError, "observability.otel.env value for #{key} must be a scalar" if value.is_a?(Hash) || value.is_a?(Array)

        ENV[key] = value.to_s unless value.nil? || ENV.key?(key)
      end
    end

    # ---------- low-level helpers -----------------------------------------

    # Fetch a nested key path from settings, e.g. dig(:provider, :model)
    def dig(*keys)
      keys.reduce(@settings) do |node, key|
        case node
        when Hash then node[key.to_s] || node[key.to_sym]
        else nil
        end
      end
    end

    def to_s
      "#<Boukensha::Config dir=#{@dir} provider=#{provider_type} model=#{model}>"
    end

    def inspect = to_s

    private

    # A real process ENV var (any of the accepted truthy/falsy spellings)
    # always wins over the YAML value; the YAML value wins over default.
    def env_boolean(env_name, yaml_value, default)
      raw = ENV[env_name]
      return truthy?(raw) unless raw.nil?
      return default if yaml_value.nil?

      truthy?(yaml_value)
    end

    def truthy?(value)
      case value
      when true, false then value
      when String      then %w[1 true yes on].include?(value.downcase)
      when Integer     then value != 0
      else !!value
      end
    end

    def resolve_dir
      raw = ENV.fetch("BOUKENSHA_DIR", nil) || DEFAULT_DIR
      Pathname.new(raw).expand_path.to_s
    end

    def load_env
      env_file = File.join(@dir, ".env")
      if File.exist?(env_file)
        Dotenv.load(env_file)
      end
    end

    def load_settings
      settings_file = File.join(@dir, "settings.yaml")
      if File.exist?(settings_file)
        YAML.safe_load(File.read(settings_file)) || {}
      else
        {}
      end
    end
  end
end
