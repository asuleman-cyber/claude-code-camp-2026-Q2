# Boukensha Experiment Lab

A small browser-local workbench for **structured experiments**, independent of the existing Sinatra monitoring dashboard. The published Site is private by default.

## Run locally

No install or build step is required. From this folder:

```sh
python3 -m http.server 8080 --directory dist
```

Open http://localhost:8080. Core verification: `node tests/core.test.cjs`.

## What it does

- Configure orchestration, optional read-only Navigator, off/session/persistent memory, replanning, judge interval, turns, session count, seed, character and model label.
- Simulate Plan / Play / Check / Remember behaviour, including conditional Chronicler writes and persistent-memory availability to future planning.
- Select two runs for comparison; designate an imported Week 2 run as reference; annotate outcomes and research notes.
- Play, pause, step and scrub individual events; inspect raw records and export JSONL.
- Review explicit memory write history, provenance and long-run assessments.
- Import agent-session and manager JSONL into an evidence index with per-role/model tokens, logged costs, explicit tool timings, errors and trace links. It does not reproduce live monitoring or invent cross-log correlation.

## Evidence and simulation boundaries

Demo runs and generated costs are **illustrative deterministic simulations**, not actual AI calls, MUD sessions, current provider price estimates or measured Week 2 results. The simulator uses a small synthetic room model; configuration changes affect its event flow. It cannot demonstrate that orchestration improves the real agent. It does not launch Ruby, Docker, or an autonomous session loop.

The Week 2 control corresponds conceptually to a Player-only agent with the existing room map and observability, but its sample outcomes are fabricated demo data. Import actual Week 2 session logs to compare recorded evidence. Match objective, character, seed where applicable, start state, model and turn budgets. Repeat matched runs before evaluating a hypothesis.

Persistent mode makes earlier simulated lessons for the same character available as a simplified planning signal; it is not real LLM digest distillation. Prior run IDs are recorded on new simulations. Session mode records lessons but does not carry them across sessions. Configuring a model changes its label, not the simulator's pricing or capabilities. The JSONL history remains the audit trail; no real persistent-memory digest is overwritten.

## Recorded formats

The parser follows `week3_capable/mud_monitor/lib/mud_monitor/session.rb` and `mud_manager/lib/mud_manager/manager_log.rb`:

- `phase: session_start`, `turn` (`n`), `response` (`task`, `model`, `usage`, optional `cost_usd`), `tool_call`, `tool_result`, `turn_end`, `plan`, `orchestrator`.
- Memory digest: `phase: orchestrator`, `role: chronicler`, `event: written`, `text`.
- Navigator: `role: navigator`; judge verdict: `role: judge`, `event: verdict`, `detail`.
- Manager events: `tool`, `elapsed_ms`, `error`.
- Optional 32-hex `trace_id` generates a Jaeger deep link. No trace IDs are invented for simulations.

Every valid record is preserved, including unknown phases. Invalid JSON lines are reported by line number. Files are imported separately, not automatically correlated. Costs use explicit numeric `cost_usd` only, with missing prices shown as unknown or partial. Token summaries use response input/output fields; cache details remain in raw records. Tool duration is shown only for explicit `elapsed_ms`; inter-event deltas are not interpreted as tool latency.

## Data and links

All imported content, notes, settings and simulated history stay in this browser's localStorage. There is no cloud sync or automatic filesystem watching. Export the workspace JSON for backup; import that file to merge saved runs by ID. Browser storage may be cleared or reach quota. Imports are capped at 20 MB per file. Do not import credentials or unredacted logs.

Set your dashboard and Jaeger URLs through the settings button. Defaults match the local repo's ports: http://localhost:4568 and http://localhost:16686. These links open on the visitor's machine; the hosted Site does not connect to the local monitoring stack.

## Architecture

`dist/core.js` contains seeded simulation, JSONL parsing and metric aggregation, usable from Node for tests. `dist/app.js` supplies the static UI, annotations, import/export and browser persistence. `dist/style.css` supplies responsive layout. No production agent code or existing dashboard is modified.
