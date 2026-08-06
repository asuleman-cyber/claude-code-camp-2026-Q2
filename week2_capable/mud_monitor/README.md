# Mud Monitor

Unified observability for a boukensha + mud_manager run: agent sessions, the
mud_manager command log, and the raw telnet feed — one app instead of three
(`week1_baseline/log_viz` + a would-be world visualizer + nothing at all for
the MUD side).

**Stack note:** I considered a Rails API + React/TS frontend, but Rails and
the `sqlite3` gem weren't installed here and were untested on Windows —
standing up that whole toolchain for what's fundamentally a log viewer felt
like a disproportionate lift. Built on Sinatra + ERB instead — the exact
stack `week1_baseline/log_viz` already proved out in this repo, with zero
new toolchain. See `week2_capable/README.md`'s Phase B section and
`docs/plans/week2_phase_A_B_C_report.md` for the full reasoning. Live
updates are meta-refresh polling, not SSE.

## Run it

```sh
cd week2_capable/mud_monitor
bundle install   # first time only
ruby bin/mud_monitor            # http://localhost:4568
```

Env vars (all optional — default to the matching path under `.boukensha/`
at the repo root):

| var | purpose |
|---|---|
| `MUD_MONITOR_SESSIONS_DIR` | agent session logs (`Boukensha::Logger`) |
| `MUD_MONITOR_MANAGER_DIR` | mud_manager's command log (`MudManager::ManagerLog`) |
| `MUD_MONITOR_TELNET_DIR` | mud_manager's raw telnet log (`MudManager::TelnetLog`) |
| `MUD_KNOWLEDGE_DB` | the agent's room/entity memory (`Boukensha::Mud::Memory::Store`) |
| `MUD_JOURNAL_DIR` | the change-capture journal (`Boukensha::Mud::Memory::Journal`) |
| `BOUKENSHA_ERROR_LOG` | the agent's caught-exception log (`Boukensha::ErrorLog`) |
| `PORT` | default `4568` |

## Pages

- `/` — session list (forked from log_viz): filter/sort/paginate, cost
  breakdown, token sparkline. A session actively being written shows a
  live badge and auto-refreshes.
- `/sessions/:id` — full transcript, plus a timing gutter on every entry
  (clock time + `+dt` since the previous entry). Sessions logged before the
  Logger's millisecond-timestamp upgrade render `~1s` pills in muted text
  rather than a falsely precise `0ms` (`Session#timing_source`).
- `/manager` — one row per tool call mud_manager's `Dispatcher` executed:
  mode, tool, args, result, elapsed time, errors highlighted.
- `/telnet` — every raw byte that crossed the socket, both directions,
  filterable by direction. This is what shows what the agent's `drain`
  calls silently discard between commands. Passwords are redacted at the
  source (`MudManager::Session#login`) and never appear here.
- `/knowledge` — the agent's room/entity memory (`Boukensha::Mud::Memory::Store`),
  read live from `knowledge.sqlite3`: rooms, exits (explored `✓` vs.
  frontier `?`), entities with cached threat/health, current player state.
  `/knowledge/rooms/:id` drills into one room's exits.
- `/progression` — the change-capture journal: every actual change to
  player state or a newly discovered room, in order — a time series
  alongside `/knowledge`'s current-snapshot view.
- `/errors` — exceptions the agent caught and logged instead of silently
  swallowing or crashing, newest first, with backtraces.

Every log/DB-backed page shows "Not enabled" with the env var to set until
its upstream source is actually configured — all of these are off by
default in `mud_manager`/`boukensha` and were turned on for this repo's live
profile as each phase landed.

## Tests

```sh
rake test
```

39 tests across `Session` parsing/timing, `ManagerLogStore`/`TelnetLogStore`/
`KnowledgeStore`/`JournalStore`/`ErrorLogStore` reading, and Rack::Test
coverage of every route including disabled-log states and path traversal.

## What's deliberately not built

No SSE (meta-refresh polling instead), no dropped/reshaped diff views
between the telnet and manager logs, no correlation IDs linking a
transcript's tool call to its exact manager-log record, no world-data
pages, and no visual room/exit graph on the Knowledge tab (the list +
room-detail pages cover the same information without the graph layout).
Manager/telnet-to-transcript correlation is by eye (same timestamp range),
not by exact ID — good enough for "does the tool call match what actually
happened," not for automated diffing. Full reasoning for each of these:
`docs/plans/week2_phase_A_B_C_report.md` and
`docs/plans/week2_phase_D_E_F_report.md`.
