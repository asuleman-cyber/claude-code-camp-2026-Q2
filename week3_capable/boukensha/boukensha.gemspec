require_relative "lib/boukensha/version"

Gem::Specification.new do |spec|
  spec.name        = "boukensha"
  spec.version     = Boukensha::VERSION
  spec.summary     = "BOUKENSHA — a tiny teaching framework for coding harnesses"
  spec.description = "Step-by-step coding harness framework. " \
                     "Set BOUKENSHA_PATH to load a specific lesson step, " \
                     "or run with defaults to use the bundled release."
  spec.authors     = ["Andrew Brown"]
  spec.email       = ["andrew@exampro.co"]
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.0"

  # All files tracked in git, plus the bin/ executable.
  #
  # prompts/ is packaged (Phase G): Config::PROMPTS_DIR resolves relative to
  # this gem, and with Planner and Judge each shipping their own default
  # prompt, an installed gem that omits them silently boots those tasks with
  # no system prompt at all.
  spec.files = Dir["lib/**/*.rb"] + Dir["prompts/**/*.md"] + ["bin/boukensha"]

  spec.bindir      = "bin"
  spec.executables = ["boukensha"]

  # MCP servers bring their own dependencies; boukensha itself only wants
  # `charm`, for the TUI (bubbletea + lipgloss + bubbles bindings) — and
  # only wants it, not needs it: lib/boukensha.rb loads the TUI in a
  # begin/rescue LoadError and falls back to the plain REPL without it.
  # Declaring this as a runtime dependency (add_dependency) made RubyGems
  # refuse to even activate the installed `boukensha` executable when
  # `charm` isn't installed — enforced by Gem.activate_bin_path before any
  # of boukensha's own code runs, so the library's own fallback never got a
  # chance to matter. `charm`'s `ntcharts` dependency has no prebuilt
  # Windows binary, so this bit on the very platform this project targets.
  # add_development_dependency isn't checked at bin-activation time, which
  # is exactly the "optional at runtime" behavior this needs.
  spec.add_development_dependency "charm"

  # Same reasoning as charm above: OpenTelemetry is optional at runtime.
  # Boukensha::Telemetry.build rescues LoadError when these aren't installed
  # and falls back to a Noop tracer, so a bare `gem install boukensha` user
  # who never turns observability.otel.enabled on shouldn't need these gems
  # — and declaring them add_dependency would (per the charm comment above)
  # block bin activation entirely for anyone who doesn't have them.
  spec.add_development_dependency "opentelemetry-api"
  spec.add_development_dependency "opentelemetry-sdk"
  spec.add_development_dependency "opentelemetry-exporter-otlp"

  # open3, net/http, and json are stdlib. Users supply their own ANTHROPIC_API_KEY.
end
