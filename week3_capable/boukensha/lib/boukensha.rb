require_relative "boukensha/version"
require_relative "boukensha/config"
require_relative "boukensha/tasks/player"

module Boukensha
  @quiet  = false
  @debug  = false
  @config = nil

  def self.config
    @config ||= Config.new
  end

  def self.quiet!
    @quiet = true
  end

  def self.loud!
    @quiet = false
  end

  def self.quiet?
    @quiet
  end

  def self.debug!
    @debug = true
  end

  def self.debug?
    @debug
  end

  # One-shot run: send a single task, get a response, return.
  #
  # The agent ships with NO tools of its own. Every tool it can call arrives
  # over an MCP connection, declared in settings.yaml's `mcp_servers:` block
  # (see Boukensha::Config#mcp_servers). Want file access? Point at a
  # filesystem MCP server. Want to play a MUD? Point at `mud-manager --mcp`.
  # Boukensha is the host; the servers own the tools.
  #
  # working_dir:      Recorded on the Context as the agent's notion of "where
  #                   it is". It registers nothing — an MCP server that touches
  #                   the filesystem is rooted by its own spawn args.
  def self.run(
    task:,
    system:           nil,
    model:            nil,
    backend:          nil,
    api_key:          nil,
    ollama_host:      "http://localhost:11434",
    log:              nil,
    context_window:   nil,
    max_output_tokens: nil,
    working_dir:      Dir.pwd,
    &block
  )
    cfg        = config                              # loads .env; populates ENV
    task_class = Tasks::Player
    task_settings, system, model, backend = task_setup(task_class, cfg, system: system, model: model, backend: backend)
    context_window ||= Models.context_window(model)
    api_key        ||= api_key_for(backend)

    perms    = task_permissions(task_settings)
    ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
    registry = Registry.new(ctx, permissions: perms)

    register_mcp_servers(registry, cfg, permissions: perms)

    dsl = RunDSL.new(registry)
    dsl.instance_eval(&block) if block
    perms.validate_referenced!(registry.tool_names)

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    logger  = Logger.new(log: log, telemetry: Telemetry.build(config: cfg), snapshot: {
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:    context_window,
      model:             model,
      provider:          backend
    })
    agent   = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger, hooks: dsl.hooks,
                        max_iterations: cfg.agent_max_iterations,
                        max_turn_tokens: cfg.agent_max_turn_tokens,
                        max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
                        task: task_class)

    ctx.add_message(:user, task)
    agent.run
  ensure
    logger&.close
  end

  # Interactive REPL — see Boukensha.run for full option documentation.
  #
  # tui: true (default) wraps the REPL in a charm-ruby TUI.  Pass tui: false or
  # use the --no-tui CLI flag to fall back to the plain terminal REPL.
  def self.repl(
    system:           nil,
    model:            nil,
    backend:          nil,
    api_key:          nil,
    ollama_host:      "http://localhost:11434",
    log:              nil,
    context_window:   nil,
    max_output_tokens: nil,
    working_dir:      Dir.pwd,
    tui:              true,
    &block
  )
    cfg        = config                              # loads .env; populates ENV
    task_class = Tasks::Player
    task_settings, system, model, backend = task_setup(task_class, cfg, system: system, model: model, backend: backend)
    context_window ||= Models.context_window(model)
    api_key        ||= api_key_for(backend)

    perms    = task_permissions(task_settings)
    ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
    registry = Registry.new(ctx, permissions: perms)

    servers = register_mcp_servers(registry, cfg, permissions: perms)

    dsl = RunDSL.new(registry)
    dsl.instance_eval(&block) if block
    perms.validate_referenced!(registry.tool_names)

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    logger  = Logger.new(log: log, telemetry: Telemetry.build(config: cfg), snapshot: {
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:    context_window,
      model:             model,
      provider:          backend
    })

    repl = Repl.new(
      context:    ctx,
      registry:   registry,
      builder:    builder,
      client:     client,
      logger:     logger,
      hooks:      dsl.hooks,
      error_log:  ErrorLog.from_env,
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      config_dir: cfg.dir,
      provider:   backend,
      model:      model,
      version:    VERSION,
      api_key:    api_key,
      servers:    server_summary(servers),
      orchestrator: Orchestrator.build(cfg: cfg, servers: servers, logger: logger, ollama_host: ollama_host)
    )

    if tui && defined?(Tui)
      Tui.new(repl).start
    else
      repl.start
    end
  rescue Interrupt
    puts "\nInterrupted."
  ensure
    logger&.close
  end

  # Register every server in settings.yaml's `mcp_servers:` block. This is the
  # agent's ONLY source of tools — boukensha ships none of its own. Nothing
  # here knows what any particular server does; a MUD daemon and a filesystem
  # server are registered by the identical code path.
  #
  # A server marked `required: false` that fails to spawn is a warning, not a
  # fatal error — the agent runs without its tools. A name collision is never
  # excused that way: it means the config asks for two tools with one name, and
  # answering by dropping one of them silently is the worst option available.
  #
  # Returns [{ name:, client:, prefix:, count: }] for the servers that came up.
  # The live client objects are part of the return value (Phase G) so a
  # subagent — the Judge, later the Navigator — can be handed the SAME
  # connection rather than spawning its own: `mud-manager --mcp` holds one
  # telnet session with one logged-in character, so a second spawn would mean
  # a second login as the same player, which the MUD rightly refuses to treat
  # as the same character. See #subagent_context.
  def self.register_mcp_servers(registry, cfg, permissions: Permissions.permissive)
    cfg.mcp_servers.each_with_object([]) do |(name, entry), servers|
      begin
        client = Tools::Mcp.register(registry, command: entry[:command], args: entry[:args],
                                               env: entry[:env], prefix: entry[:prefix],
                                               permissions: permissions)
        servers << { name: name, client: client, prefix: entry[:prefix], count: client.tools.size }
      rescue Tools::Mcp::CollisionError
        raise
      rescue StandardError => e
        raise "boukensha: MCP server '#{name}' failed to start: #{e.message}" if entry[:required]
        warn "[boukensha] optional MCP server '#{name}' failed to start: #{e.message} — continuing without its tools"
      end
    end
  end
  private_class_method :register_mcp_servers

  # { server_name => tool_count } — the shape the REPL banner wants.
  def self.server_summary(servers)
    servers.to_h { |s| [s[:name], s[:count]] }
  end
  private_class_method :server_summary

  # A throwaway Context+Registry for a subagent (Judge now; Navigator in
  # Phase I), sharing `servers`' already-connected MCP clients.
  #
  # Isolation is the point. The subagent gets its own Context, so nothing it
  # says, sees, or spends lands in the Player's message history — the Player's
  # next turn looks exactly as it would have if the subagent had never run.
  # It gets its own Registry built with its own Permissions, so its tool
  # surface is narrower than the Player's even though both draw on the same
  # MCP connection.
  def self.subagent_context(servers, permissions:, system:, context_window:)
    ctx      = Context.new(system: system, context_window: context_window)
    registry = Registry.new(ctx, permissions: permissions)
    servers.each do |server|
      Tools::Mcp.register_client(registry, server[:client], prefix: server[:prefix], permissions: permissions)
    end
    [ctx, registry]
  end

  # Resolve a task's system prompt / model / provider from settings.yaml,
  # letting an explicit argument win over config. Shared by every entry point
  # so Planner and Judge read their settings exactly the way Player does.
  #
  # Public because Orchestrator calls it, not because it is a supported API —
  # #run and #repl remain the entry points anything outside this gem should use.
  def self.task_setup(task_class, cfg, system: nil, model: nil, backend: nil)
    settings = cfg.tasks(task_class.task_name)
    [
      settings,
      system  || task_class.system_prompt(settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR),
      model   || task_class.model(settings),
      (backend || task_class.provider(settings)).to_sym
    ]
  end

  def self.api_key_for(backend)
    case backend
    when :anthropic    then ENV["ANTHROPIC_API_KEY"]
    when :openai       then ENV["OPENAI_API_KEY"]
    when :gemini       then ENV["GEMINI_API_KEY"]
    when :ollama_cloud then ENV["OLLAMA_API_KEY"]
    end
  end

  def self.build_backend(backend, model:, api_key:, ollama_host: "http://localhost:11434")
    case backend
    when :anthropic    then Backends::Anthropic.new(api_key: api_key, model: model)
    when :openai       then Backends::OpenAI.new(api_key: api_key, model: model)
    when :gemini       then Backends::Gemini.new(api_key: api_key, model: model)
    when :ollama       then Backends::Ollama.new(host: ollama_host, model: model)
    when :ollama_cloud then Backends::OllamaCloud.new(api_key: api_key, model: model)
    else raise ArgumentError, "Unknown backend #{backend.inspect}. Use :anthropic, :openai, :gemini, :ollama, or :ollama_cloud."
    end
  end

  # Builds this task's Permissions from its settings.yaml `allow:` block
  # (absent → permissive, current default — see Permissions).
  def self.task_permissions(task_settings)
    allow = task_settings.is_a?(Hash) ? (task_settings["allow"] || task_settings[:allow]) : nil
    Permissions.new(allow)
  end
  private_class_method :task_permissions
end

require_relative "boukensha/tool"
require_relative "boukensha/message"
require_relative "boukensha/models"
require_relative "boukensha/context"
require_relative "boukensha/errors"
require_relative "boukensha/permissions"
require_relative "boukensha/registry"
require_relative "boukensha/hooks"
require_relative "boukensha/error_log"
require_relative "boukensha/prompt_builder"
require_relative "boukensha/telemetry"
require_relative "boukensha/logger"
require_relative "boukensha/backends/base"
require_relative "boukensha/backends/anthropic"
require_relative "boukensha/backends/gemini"
require_relative "boukensha/backends/ollama"
require_relative "boukensha/backends/ollama_cloud"
require_relative "boukensha/backends/openai"
require_relative "boukensha/client"
require_relative "boukensha/agent"
require_relative "boukensha/orchestrator"
require_relative "boukensha/run_dsl"
require_relative "boukensha/repl"
require_relative "boukensha/tools/mcp"
require_relative "boukensha/mud/room_survey"

# The TUI needs the `charm` gem (bubbletea/lipgloss/bubbles). That gem's
# ntcharts dependency ships a native extension with no prebuilt Windows
# archive, so `gem install charm` can fail on Windows even though nothing in
# this file's TUI actually uses ntcharts. `Boukensha.repl` already guards
# every call site with `if tui && defined?(Tui)`, so letting this require
# fail quietly here — rather than crashing `require "boukensha"` itself — is
# enough to fall back to the plain terminal REPL everywhere charm isn't
# installed.
begin
  require_relative "boukensha/tui"
rescue LoadError
end
