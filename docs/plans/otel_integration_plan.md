# OpenTelemetry Integration Plan

**Status: Phases 1–3 done, plus a follow-up.** Tutorial:
[`docs/otel.md`](../otel.md). Phase 3 (mud_monitor trace link) was verified
against a real, live chain — not just unit tests: a fake-backend
`Agent#run` with `BOUKENSHA_OTEL_ENABLED=true` against a live `--profile
jaeger` collector produced a real trace, confirmed present via Jaeger's own
API, and mud_monitor's session page rendered a working link that resolves
to that exact trace. Later verified again end-to-end against a **real**
boukensha run (real MUD, real Anthropic API key) — which also caught a
real bug: the installed gem was stale from before the `current_ids` fix, so
the first live run produced a trace but no `trace_id` in the JSONL.
Rebuilding (`bin/rebuild`) fixed it; the lesson is "rebuild after editing
source, verification against source alone isn't enough."

**Follow-up beyond the original 3 phases:** the initial design was one flat
span per turn with untimed events inside it — technically correct, but
close to useless to actually look at: one bar, no breakdown of where time
went. Added `boukensha.model_call` and `boukensha.tool_call` as child spans
(nested under `boukensha.turn`, siblings of each other) so a trace renders
as a real waterfall. Confirmed on a live run where two tool calls (MUD
login hanging) showed up as two ~11.5s bars against ~1-3s model-call bars
in a 77s turn — exactly the kind of thing a flat span can't show and the
JSONL transcript doesn't make obvious either.
Deviations from the plan below, found while actually building it:
- `apply_otel_environment!` moved inside `Telemetry.build`'s rescue —
  as originally planned it could raise past the rescue and crash a run
  over a malformed `observability.otel.env`, which defeats the point of
  having a fallback at all.
- Added `current_ids` (not in the original phase breakdown) so
  `trace_id`/`span_id` land on every JSONL line while a span is open —
  Phase 3's mud_monitor link needs this data to exist first.
- No frame/kind/nested-span model: this codebase's `Logger`/`Agent` have no
  stack architecture to hang nested spans on, so it's one flat span per
  `Agent#run` call rather than per tool call. Simpler, matches the stated
  goal ("one trace per turn") exactly, costs per-tool-call granularity.
- OTel gems are `add_development_dependency` in the gemspec, not
  `add_dependency` — this codebase already hit and fixed the exact same
  problem for `charm` (see `boukensha.gemspec`'s comment): a hard runtime
  dependency that isn't installed blocks `Gem.activate_bin_path` before any
  of Boukensha's own code — including `Telemetry.build`'s own
  rescue — gets a chance to run.

**Source:** adapted directly from the course-provided reference at
`claude-code-camp-2026-Q2-main/week2_capable/observability/` and
`claude-code-camp-2026-Q2-main/week2_capable/boukensha/lib/boukensha/telemetry/`
— approved course material, restructured to fit this project's actual layout
under `week2_observability/`.

## Goal

One OTel trace per Boukensha agent turn, exported over OTLP to a local
collector, stored in Tempo, browsable in Grafana — plus a `trace_id` deep
link surfaced in `mud_monitor`'s session view so a transcript entry can jump
straight to its trace. Off by default; zero behavior change until opted in.

## Architecture

```
Boukensha (Ruby, OTLP/HTTP) → OTel Collector (docker) → Tempo → Grafana (TraceQL)
                                        ↘ Jaeger (lighter alternative backend)
```

Four docker-compose profiles, only one running at a time, all exposing the
same OTLP ports so Boukensha's config never changes:

| Profile | What starts | UI |
| --- | --- | --- |
| `debug` | Collector debug exporter + zPages | `http://localhost:55679/debug/tracez` |
| `jaeger` | Collector + Jaeger | `http://localhost:16686` |
| `tempo` | Collector + Tempo + Grafana | `http://localhost:3001/explore` |
| `compare` | Collector fan-out + both backends | both UIs |

`debug` is the cheapest way to confirm the collector is receiving OTLP at
all, before standing up Tempo/Grafana. `jaeger` is the recommended first
visual test.

## Phase 1 — Infra (`week2_observability/observability/`)

Bring in the compose stack, adapted to this repo's path:

- `docker-compose.yml` — collector (image `otel/opentelemetry-collector-contrib`),
  Jaeger, Tempo, Grafana services behind the 4 profiles above.
- `collector/{debug,jaeger,tempo,compare}.yaml` — OTLP receiver (grpc :4317,
  http :4318) → memory_limiter/batch processors → the matching exporter(s).
- `tempo/tempo.yaml` — local-disk trace storage, OTLP receiver on :4317/:4318.
- `grafana/provisioning/datasources/tempo.yaml` — auto-provisions the Tempo
  datasource so Grafana Explore works with zero manual setup.

All ports bind to `127.0.0.1` — dev-only, no auth, don't expose publicly.
Grafana defaults to `3001` (override via `BOUKENSHA_GRAFANA_PORT`) to avoid
clashing with anything already on `3000` in this dev environment.

Run it:

```sh
docker compose -f week2_observability/observability/docker-compose.yml --profile jaeger up
```

## Phase 2 — Boukensha instrumentation

**Gem deps** — add to `boukensha.gemspec`:

```ruby
spec.add_dependency "opentelemetry-api", "~> 1.0"
spec.add_dependency "opentelemetry-sdk", "~> 1.0"
spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.30"
```

**New files:**

- `lib/boukensha/telemetry.rb` — factory. `Telemetry.build(config:)` returns
  a `Noop` unless `config.otel_enabled?`; any load/config error during setup
  is caught, logged to the existing error log, and falls back to `Noop`
  rather than breaking a run over a bad exporter config.
- `lib/boukensha/telemetry/noop.rb` — null object with the same interface
  (`in_span`, `capture_event`, `force_flush`, `shutdown`, `current_ids`,
  `propagation_carrier`) so the rest of the codebase never branches on
  whether OTel is enabled.
- `lib/boukensha/telemetry/open_telemetry.rb` — real span wrapper:
  - `in_span(name, kind:, attributes:, root:)` — starts/finishes a span,
    propagates parent context.
  - `capture_event(event)` — turns logger events into span events, pinned to
    **OpenTelemetry GenAI semantic conventions 1.37.0**; only
    `prompt`/`response`/`tool_call`/`tool_result`/`injected_context`/
    `context_transform` phases get content, and only if `capture_content` is
    on — `reasoning` phases only record presence, never the content itself.
  - Secret redaction (`authorization|api[_-]?key|token|password|secret|credential`
    keys, `Bearer …` / `sk-…` value patterns) applied before anything
    touches a span.
  - `force_flush` / `shutdown` for clean process exit.

**`config.rb` additions:**

```ruby
def otel_enabled?
  env_boolean("BOUKENSHA_OTEL_ENABLED", dig(:observability, :otel, :enabled), false)
end
# + otel_capture_content?, otel_content_max_bytes, apply_otel_environment!
```

`apply_otel_environment!` pushes `observability.otel.env.OTEL_*` keys from
settings.yaml into `ENV` before the SDK configures — a real process env var
always wins, so secrets like `OTEL_EXPORTER_OTLP_HEADERS` never need to live
in committed YAML.

**`logger.rb` wiring:** build `@telemetry` once (`Noop` by default), wrap
each top-level turn in `@telemetry.in_span(...)`, feed every logged event
through `@telemetry.capture_event(event)`, `force_flush` on shutdown.

**Opt-in config** (`~/.boukensha/settings.yaml`, disabled unless set):

```yaml
observability:
  otel:
    enabled: true
    capture_content: false
    env:
      OTEL_SERVICE_NAME: boukensha
      OTEL_EXPORTER_OTLP_ENDPOINT: http://localhost:4318
      OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
      OTEL_TRACES_EXPORTER: otlp
```

## Phase 3 — mud_monitor: trace deep link (optional, cheap)

Once Phase 2 is live, every JSONL event Boukensha logs already carries
`trace_id`/`span_id`. `mud_monitor`'s session view just needs to render a
link from those two fields to `http://localhost:3001/explore?...traceId=<id>`
(Tempo) or the Jaeger UI, depending on which profile is running. No new
instrumentation needed in `mud_monitor` itself — it stays a pure log reader,
consistent with its existing "no correlation IDs" disclaimer in its README;
this phase is exactly the correlation piece, made cheap because Boukensha
already emits the IDs.

## Testing

- Unit: config parsing rejects malformed `observability.otel.env` keys,
  `Noop` is a true no-op, `OpenTelemetry` wrapper's attribute cleaning and
  redaction.
- Manual: `debug` profile + zPages to confirm OTLP traffic without needing
  Tempo/Grafana running.

## Order of work

1. **Phase 1** (infra) — fastest to verify in isolation (`--profile debug up`
   + zPages), no code changes.
2. **Phase 2** (code) — gated behind `enabled: false` by default, so it's
   zero-risk to land ahead of actually turning it on.
3. **Phase 3** (mud_monitor link) — small, optional, depends on Phase 2 being
   live to have real `trace_id`s to link.

Once Phase 1–2 are built, follow up with `docs/otel.md` as a
run-it-yourself tutorial (setup, profile choice, TraceQL query, config
reference) — writing that now would just restate this plan since nothing
exists yet to document.
