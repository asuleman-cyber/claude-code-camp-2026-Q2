week2_capable contains both week 2 and week 3.
Week 2 was originally capable but was pushed out a week
Week 2 became observaiblity
Week 3 became capable

## Setup

This folder started empty. The foundation was seeded from the two most
advanced pieces already built elsewhere in this repo, not written from
scratch and not copied from a colleague's finished solution:

- `boukensha/` ← forked from [`week1_baseline/ruby/12_context`](../week1_baseline/ruby/12_context)
  (Step 12 — full context management, MCP host, terminal UI)
- `mud_manager/` ← forked from [`week0_explore/mud_manager`](../week0_explore/mud_manager)
  (v0.2.0 — Telnet session, admin primitives, MCP daemon)

Both now live as siblings under this directory and build/run independently
of their originals. Two things were changed when forking:

1. **Cross-package paths.** `boukensha/test/helper.rb` and
   `boukensha/examples/mcp_mud_demo.rb` used to reach `mud_manager` via
   `../../../../week0_explore/mud_manager` (correct from the old, deeper
   lesson-step location). They now point at the sibling `../../mud_manager`.
2. **TUI load guard.** `boukensha/lib/boukensha.rb` now wraps
   `require_relative "boukensha/tui"` in `begin/rescue LoadError`. See
   "Known issue: TUI / charm on Windows" below — without this, `require
   "boukensha"` crashed outright before `--no-tui` could even take effect.

Nothing in `week1_baseline/ruby/12_context` or `week0_explore/mud_manager`
was modified — those stay as pristine lesson/reference material.

### Known issue: TUI / charm on Windows

`boukensha`'s TUI depends on the `charm` gem, which pulls in `ntcharts` — a
native extension with no prebuilt Windows archive (`gem install charm` fails
here with a Go-archive build error). Until `charm` is installed (e.g. via
WSL, or a local Go toolchain building `ntcharts` from source), run:

```
boukensha --no-tui
```

The `require_relative "boukensha/tui"` guard means `require "boukensha"`
still succeeds without `charm` installed, and `Boukensha.repl` already falls
back to the plain terminal REPL via `if tui && defined?(Tui)`. If `charm`
ever gets installed on this machine, TUI mode starts working automatically —
no further code change needed.

### Roadmap

The phased plan for building this out toward parity with (and eventually
past) the reference implementation is
[`docs/plans/week2_catchup_plan.md`](../docs/plans/week2_catchup_plan.md).

## Phase A — navigation debuggable (done)

Source of truth: `docs/plans/week2_catchup_plan.md` Phase A, and the
reference plan docs it links to under
`claude-code-camp-2026-Q2-main/docs/plans/week_2/`.

- **`bin/reset`** — standalone Ruby script, uses `MudManager::Session`
  directly (no MCP daemon, no agent). Logs in as the player (so a live
  target exists), then as admin, runs `goto <room>` + `trans <player>`, and
  quits both cleanly.

  ```sh
  ruby week2_capable/bin/reset
  # or with explicit credentials:
  ADMIN_USERNAME=admin ADMIN_PASSWORD=password \
  PLAYER_USERNAME=dummy PLAYER_PASSWORD=helloworld \
  ruby week2_capable/bin/reset
  ```

  `PLAYER_USERNAME`/`PLAYER_PASSWORD` fall back to `MUD_NAME`/`MUD_PASSWORD`
  (the same pair `.boukensha/settings.yaml`'s `mcp_servers.mud` block reads),
  so it works with no extra config in the common case. `START_ROOM_VNUM`
  defaults to `3001` (The Temple Of Midgaard).

  New `MudManager::Primitives`: `admin_goto(target)`, `admin_transfer(target)`
  — immortal-only, never exposed as MCP tools (see the comment above them in
  `mud_manager/lib/mud_manager/primitives.rb`).

- **`inspect` composite tool** — new MCP tool in the `mud_manager` daemon:
  `look` + `exits` in one round trip instead of two tool calls
  (`mud_manager/lib/mud_manager/mcp/dispatcher.rb#dispatch_inspect`). Tool
  count went from 26 → 27.

- **Tool permissions (`allow:`)** — new `Boukensha::Permissions`
  (`boukensha/lib/boukensha/permissions.rb`), a pure allowlist, default-deny
  gate enforced in `Registry#tool`/`#dispatch` — the one place *every*
  registration path (MCP discovery **and** native `RunDSL#tool`) goes
  through, so a task's tool surface is one allowlist, not "the allowlist plus
  whatever else got registered." No `allow:` block in a task's
  `settings.yaml` (today's default for every task) means fully permissive —
  nothing changes unless a task opts in:

  ```yaml
  tasks:
    player:
      allow:
        - move
        - attack
        - check(kind: score|inventory|equipment)
        - inspect
  ```

  Rule grammar: bare tool name, or `tool(param: value|value2)` (`*` = any
  value); a bare rule matches under any MCP `prefix:`. A rule naming an
  unknown tool, unknown parameter, or an out-of-enum value fails loudly at
  boot (`Permissions::InvalidRuleError`) rather than silently at runtime.
  This is **not yet turned on** in the live `.boukensha/settings.yaml` — the
  engine is built and tested, wiring it into the running profile is a
  separate, deliberate step since it immediately restricts what the live
  agent can do.

- **`bin/rebuild`** — rebuilds and reinstalls both gems from source
  (`gem build` + `gem install --ignore-dependencies`, so boukensha's
  unmet `charm` dependency doesn't block the install — see the Windows/TUI
  note above).

  ```sh
  ruby week2_capable/bin/rebuild
  ```

Tests: `mud_manager` 22 runs / 163 assertions, `boukensha` 50 runs / 133
assertions, all passing (`rake test` in each gem's directory).

## Phase B — get visibility before optimizing further (done)

Source of truth: `docs/plans/week2_catchup_plan.md` Phase B, and
`claude-code-camp-2026-Q2-main/docs/plans/week_2/mud_monitor.md`.

**Stack decision:** the reference doc specifies Rails 8 API + React/TS.
Neither Rails nor the `sqlite3` gem are installed here, and both are
untested on this Windows box. Standing up that toolchain from scratch for a
log viewer was a disproportionate lift, so this build extends
**Sinatra + ERB** — the exact stack `week1_baseline/log_viz` already proved
out in this repo — with **meta-refresh polling** instead of SSE for live
updates. Full reasoning and scope cuts: `mud_monitor/README.md`.

- **`mud_manager/lib/mud_manager/manager_log.rb` + `telnet_log.rb`** — two
  new independent, daily-rotated JSONL logs, each off by default:
  - `ManagerLog`: one record per tool call `Dispatcher#call` executes (tool,
    args, elapsed time, error). Wired in via `Dispatcher#with_manager_log`.
  - `TelnetLog`: every raw byte crossing the socket, both directions,
    written from `Session`'s reader thread + `#send_command`. The login
    password is redacted at the source (`send_command(password, redact:
    true)`) — verified by a test that greps the log file for the literal
    password after a full `FakeMud` login.
  - Both enabled for the live profile via `MUD_MANAGER_LOG_DIR`/
    `MUD_TELNET_LOG_DIR` in `.boukensha/settings.yaml`'s `mud:` server
    block — this *is* live (additive/observational only, unlike Phase A's
    `allow:` engine which was deliberately left off).
- **`boukensha/lib/boukensha/logger.rb`** — `at` gained millisecond
  resolution (`iso8601(3)`) plus a new `mono_ms` field, so "duration
  between commands" is actually meaningful instead of ±1s-quantized.
  Backward compatible: still valid ISO8601, old sessions just render
  coarser.
- **`mud_monitor/`** — new Sinatra app: session transcript (forked from
  `log_viz`, cost breakdown + sparkline came along for free) plus new
  `/manager` and `/telnet` pages, a per-entry timing gutter, and live
  badges/auto-refresh on anything actively being written.

Tests: `mud_manager` 34 runs / 203 assertions, `boukensha` 50 runs / 133
assertions, `mud_monitor` 26 runs / 69 assertions — all passing. Verified
live against the real CircleMUD (not just `FakeMud`): a real `look` call
produced a manager-log record and telnet-log chunks, rendered correctly in
the running app, with the login password confirmed absent from the
rendered telnet page.

**Not built** (see `mud_monitor/README.md` for the full list): SSE, the
`diffs/dropped`/`diffs/reshaped` derived views, exact tool-call-to-manager-
record correlation IDs, world-data pages, and the `Boukensha::Logger`
task-stack fix (Amendment A — `inspect_room` currently still opens a second
session file; out of scope until Phase C adds `inspect_room`).

## Phase C — fix the actual navigation problem (done)

Source of truth: `docs/plans/week2_catchup_plan.md` Phase C, and
`claude-code-camp-2026-Q2-main/docs/plans/week_2/scripted_room_survey.md`.

Went straight to the deterministic script the source plan converges on —
never built the LLM-driven `room_inspector` ReAct loop it replaces (Phase A
already decided to skip that detour).

- **`boukensha/lib/boukensha/tools/room_parser.rb`** — pure text → Hash, no
  I/O. Splits the `inspect` MCP tool's output (Phase A) into name,
  description, vitals, `exit_targets`, and mob/object entity lines,
  classified by ANSI color (`\e[0;33m` yellow = mob, `\e[0;32m` green =
  object — verified against tbaMUD source and this MUD's own captured
  output, not assumed). Deliberately doesn't attempt `look_candidates`
  (hidden examinable nouns) — the source plan's own analysis (§7.1, §9–10)
  shows that's the one field that genuinely wants a model/NLP layer, well
  past this phase's scope.
- **`boukensha/lib/boukensha/tools/room_survey.rb`** — the orchestrator:
  `poll` → `inspect` → classify → per-*distinct*-mob `consider`/`examine`
  (deduplicated, so three identical mobs cost one round-trip pair, not
  three) → a compact `[here] ...` summary. Zero LLM calls. Miss-detection
  uses this MUD's *actual* verified responses (`"Consider killing who?"` /
  `"You do not see that here."`) — the reference doc's assumed message
  (`"They aren't here."`) doesn't match this server; always verify against
  the real thing rather than porting an assumption.
- **`inspect_room`** — new native tool, wired in `boukensha_loader.rb`.
  Drives `RoomSurvey` through `RunDSL#dispatch` (new), so its MUD calls go
  through the same `Registry`/`allow:` gate as everything else — no
  separate, ungated path. The MCP `prefix:` is read from config
  (`cfg.mcp_servers["mud"][:prefix]`), not hardcoded, so it stays correct
  if `settings.yaml` ever renames it. The keyword cache is a closure
  variable scoped to one REPL session.

**Simplification versus the source plan:** no ranked-candidate retry on a
keyword miss (the plan's §3.4 "retry right-to-left, give up after 2
misses") — `RoomParser.guess_keyword` returns one best guess; a miss is
cached as unresolved rather than retried. Revisit if misses turn out to be
common in practice.

Tests: `boukensha` gained 14 tests (`test_room_parser.rb`,
`test_room_survey.rb`) built from **real captures off the live CircleMUD**
(a green-object room and a yellow-mob room — "The Circle Of Stones" with an
actual pit fiend), not hand-written fixtures, per the source plan's own
testing guidance. `boukensha` now 64 runs / 189 assertions.

**Verified live, twice:** once driving `Boukensha::Mcp::Dispatcher` directly
to capture real fixtures, and once through the *actual* `inspect_room`
native-tool wiring (`Registry#tool` → `RunDSL#dispatch` → the real MCP
daemon) — moved into the pit fiend's room and got back `mobs: The pit fiend
is sitting here. (You ARE mad!; The pit fiend is in excellent condition.)`
with zero LLM calls.