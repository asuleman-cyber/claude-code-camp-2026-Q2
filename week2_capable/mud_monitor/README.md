# Mud Monitor

Unified observability for a boukensha + mud_manager run: agent sessions, the
mud_manager command log, and the raw telnet feed — one app instead of three
(`week1_baseline/log_viz` + a would-be world visualizer + nothing at all for
the MUD side), per the goal in
`claude-code-camp-2026-Q2-main/docs/plans/week_2/mud_monitor.md`.

**Stack note:** that reference doc specifies a Rails 8 API + React/TS
frontend. This build uses Sinatra + ERB instead — the exact stack
`week1_baseline/log_viz` already proved out in this repo, with zero new
toolchain (Rails and the `sqlite3` gem aren't installed here and are
untested on Windows). See `week2_capable/README.md`'s Phase B section for
the full reasoning. Live updates are meta-refresh polling, not SSE.

## Run it

```sh
cd week2_capable/mud_monitor
bundle install   # first time only
ruby bin/mud_monitor            # http://localhost:4568
```

Env vars (all optional — default to `.boukensha/{sessions,manager,telnet}`
at the repo root):

| var | purpose |
|---|---|
| `MUD_MONITOR_SESSIONS_DIR` | agent session logs (`Boukensha::Logger`) |
| `MUD_MONITOR_MANAGER_DIR` | mud_manager's command log (`MudManager::ManagerLog`) |
| `MUD_MONITOR_TELNET_DIR` | mud_manager's raw telnet log (`MudManager::TelnetLog`) |
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

Both log pages show "Not enabled" with the env var to set until
`MUD_MANAGER_LOG_DIR`/`MUD_TELNET_LOG_DIR` are configured on the `mud:` MCP
server in `.boukensha/settings.yaml` (already done for this repo's live
profile) — both logs are off by default upstream in mud_manager.

## Tests

```sh
rake test
```

26 tests: `Session` parsing/timing, `ManagerLogStore`/`TelnetLogStore`
reading, and Rack::Test coverage of all four routes including the
disabled-log and path-traversal cases.

## What's deliberately not built (Phase B scope cut)

Per `docs/plans/week2_catchup_plan.md` Phase B: no SSE, no `diffs/dropped`
or `diffs/reshaped` derived views, no correlation IDs linking a transcript's
tool call to its exact manager-log record, no world-data pages, no
`Boukensha::Logger` task-stack fix (Amendment A — the "one `inspect_room`
call opens a second session file" bug). The reference implementation itself
only shipped through its phase 6 of 10; this build covers the phase 1
(session transcript) + phase 4 (manager log) + phase 5 (telnet log)
equivalent, with a lighter-weight timing model (phase 2's "lite" version)
layered in. Manager/telnet-to-transcript correlation is by eye (same
timestamp range), not by exact ID — good enough for "does the tool call
match what actually happened," not for automated diffing.
