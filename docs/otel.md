# OpenTelemetry tracing — how to run it

Design doc: [`docs/plans/otel_integration_plan.md`](plans/otel_integration_plan.md).
This page is the "just run it" version.

Off by default. Nothing here changes behavior for a run that doesn't opt in.

## 0. Which backend do I actually want?

- **Jaeger** — best for "what happened in this one turn": open a trace, see
  the waterfall (which model call or tool call ate the time), done. No
  query language, no dashboards.
- **Grafana + Tempo** — same trace view (Explore → TraceQL), plus the thing
  Jaeger can't do: query *across* traces — `{ resource.service.name =
  "boukensha" }` today, narrower queries (by duration, by attribute) once
  you have enough traces for that to be interesting. Worth it once you're
  asking "which turns are slow" rather than "why was *this* turn slow."

`compare` runs both at once (one collector, fanned out to both backends) —
reasonable default if you don't know yet which you'll want.

## 1. Start a backend

From the repo root, pick one profile (only one at a time — they share the
same OTLP ports):

```sh
docker compose -f week2_observability/observability/docker-compose.yml --profile compare up -d
```

| Profile | What starts | UI |
| --- | --- | --- |
| `debug` | Collector debug exporter + zPages | `http://localhost:55679/debug/tracez` |
| `jaeger` | Collector + Jaeger | `http://localhost:16686` |
| `tempo` | Collector + Tempo + Grafana | `http://localhost:3001/explore` |
| `compare` | Collector fan-out + both backends | both UIs |

Only one profile at a time — they all bind the same OTLP ports. Switching
means stopping the current one first:

```sh
docker compose -f week2_observability/observability/docker-compose.yml --profile jaeger down
docker compose -f week2_observability/observability/docker-compose.yml --profile compare up -d
```

`debug` is the cheapest way to confirm OTLP traffic is arriving at all,
without needing either UI up.

Stop it:

```sh
docker compose -f week2_observability/observability/docker-compose.yml --profile jaeger down
```

## 2. Turn tracing on in Boukensha

Add to `~/.boukensha/settings.yaml`:

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

`capture_content: true` also attaches prompt/response/tool_call/tool_result/
plan text to span events (redacted for anything that looks like a secret
first). Leave it `false` for metadata-only traces — span names, timings,
token counts, error status — with zero risk of leaking a MUD conversation
or an API key into whatever backend you pointed the collector at.

Only uppercase `OTEL_*` keys are accepted under `env:`; anything else
raises. A real process environment variable always wins over the YAML
value, so `BOUKENSHA_OTEL_ENABLED=false ruby ...` overrides the file
without editing it, and secrets like `OTEL_EXPORTER_OTLP_HEADERS` belong in
the real environment, never committed to `settings.yaml`.

## 3. Run Boukensha normally

```sh
boukensha
```

or `Boukensha.run(...)` / `Boukensha.repl(...)` if you're driving it from
Ruby directly — no code changes needed at the call site either way.

Each top-level turn (`Agent#run`) becomes a `boukensha.turn` span. Nested
under it: a `boukensha.model_call` child span for every model round trip,
and a `boukensha.tool_call` child span for every tool dispatch — so a trace
renders as an actual waterfall (which call took the time?), not one bar
with a flat list of instant markers. Everything Boukensha already logs to
the session JSONL — iterations, prompts, tool results, the final response —
still becomes an event on whichever span was open when it was logged, so
the trace and the JSONL log tell the same story from two different angles.

## 4. Find your trace

**Jaeger** (`http://localhost:16686`): service `boukensha` → pick a trace
→ each event within the `boukensha.turn` span is one step of that turn.

**Grafana + Tempo** (`http://localhost:3001/explore`, `tempo` or `compare`
profile): select the provisioned Tempo data source, TraceQL:

```traceql
{ resource.service.name = "boukensha" }
```

**From mud_monitor** (`http://localhost:4568/sessions/<id>`): any entry
logged while a span was open shows a small `trace ab12cd34…` link next to
its timestamp — click it to jump straight to that trace in Jaeger. Backed
by the same `trace_id`/`span_id` fields `Logger#write_log` adds to every
JSONL line (`current_ids` in
`boukensha/lib/boukensha/telemetry/open_telemetry.rb`); grep a session file
for `trace_id` if you want it without starting mud_monitor.

## Troubleshooting

- **No spans showing up**: confirm `observability.otel.enabled: true` is
  actually being read — `BOUKENSHA_OTEL_ENABLED` (a real env var) silently
  overrides the YAML if it's set to something falsy anywhere in your shell.
- **"OpenTelemetry disabled: ..." printed on stderr at startup**: the SDK
  failed to load or configure — check the message, then
  `BOUKENSHA_ERROR_LOG` (if set) has the full backtrace. Boukensha always
  falls back to running with tracing off rather than crashing the agent
  over a bad exporter config.
- **Spans open but nothing in Jaeger/Tempo**: check the collector profile
  is actually up (`docker compose ... ps`) and `OTEL_EXPORTER_OTLP_ENDPOINT`
  matches its port (4318 for HTTP, matching `OTEL_EXPORTER_OTLP_PROTOCOL:
  http/protobuf` above).
- **Port 3000/4317/4318 already in use**: another profile is probably still
  running — `docker compose ... down` it first, or override Grafana's port
  with `BOUKENSHA_GRAFANA_PORT`.
