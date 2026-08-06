# Week 2 — Phases A, B, C: what I built, what I skipped, and what to try

Companion to [`week2_catchup_plan.md`](week2_catchup_plan.md) and the follow-up
[`week2_phase_D_E_F_report.md`](week2_phase_D_E_F_report.md). This one covers the
first half of week 2 — getting the agent from "no tooling at all" to a fast,
deterministic room survey with real observability underneath it.

Same as the later report: the overall roadmap — reset the world, see what the agent
sees, replace slow room inspection with something fast — was inspired by watching
Andrew work through the same problems in his own run at this camp. Everything below
is my own implementation, built against my own codebase (my own fork of the agent and
the MUD client), not a port of his.

**Test totals by the end of Phase C:** `boukensha` 64 runs / 189 assertions,
`mud_manager` 22 runs / 163 assertions — all green. Everything marked "verified live"
below was run against the real CircleMUD on `localhost:4000`, not just fixtures.

---

## Before Phase A: the foundation

Before any of the three phases below, `week2_capable/` needed a starting point. I
forked my own most-advanced week 1 work forward — my final-stage Ruby agent (the one
with full context management and MCP support) became `week2_capable/boukensha`, and
my own MUD client gem became `week2_capable/mud_manager`. Two things had to be fixed
in the fork:

- **Cross-package paths.** The test suite and demo scripts reached the MUD client via
  a relative path that assumed the old, deeper directory layout. Repointed to the new
  sibling location.
- **A real Windows blocker.** The agent's terminal UI depends on a gem whose native
  extension has no prebuilt Windows binary — `gem install` for it fails outright with
  a Go-archive build error. Since the agent's own code already had a fallback path
  (`--no-tui`) that was supposed to handle exactly this, the fix was small: wrap the
  TUI's `require` in a `begin/rescue LoadError` so the rest of the agent loads and
  runs fine without it, degrading to the plain terminal REPL automatically instead of
  crashing on boot.

Verified with both gems' test suites green in the new location before touching
anything else (`mud_manager` 16/146, `boukensha` 22/66).

---

## Phase A — make navigation debuggable (done)

**Goal going in:** stop wasting turns and tokens on manual resets and repeated
`look`+`exits` calls.

### What got built

| Piece | File | What it does |
|---|---|---|
| Admin primitives | `mud_manager/lib/mud_manager/primitives.rb` | `admin_goto`/`admin_transfer` — immortal-only commands, never exposed as MCP tools, used only by the reset script below. |
| Reset script | `week2_capable/bin/reset` | Standalone Ruby script, no MCP daemon involved: logs in as the player (so there's a live target), logs in as admin, `goto`s the starting room, `trans`fers the player to it, quits both cleanly. |
| Composite `inspect` tool | `mud_manager/lib/mud_manager/mcp/dispatcher.rb` | `look` + `exits` in one MCP round trip instead of two separate tool calls. Tool count went from 26 to 27. |
| `Boukensha::Permissions` | `boukensha/lib/boukensha/permissions.rb` | A pure allowlist, default-deny gate — `tool(param: value|value2)` rule grammar, `*` for any value, bare rule names matching under any MCP prefix. Enforced in `Registry#tool`/`#dispatch`, the one place every registration path (MCP-derived and native) goes through. No `allow:` block on a task = fully permissive, so nothing changes unless a task opts in. |
| `week2_capable/bin/rebuild` | — | Rebuilds and reinstalls both gems from source. Uses `--ignore-dependencies` on install so the unmet TUI dependency (see above) doesn't block installing the other 95% of the gem. |

### Verified live

Drove the real `Dispatcher` against the live game to build test fixtures, then ran
`bin/reset` end-to-end against a fake server standing in for the MUD: both logins
succeed, `goto`/`trans` fire in the right order, both sessions quit cleanly, exit 0.

### Real bugs this caught

- **A collision-bookkeeping-order bug** surfaced while wiring permissions into the MCP
  tool-discovery loop. The code that tracked "which tool names has this task already
  claimed" ran *before* checking whether a tool actually passed the new permission
  gate — so a tool the allowlist rejected could still occupy a name slot, and a later,
  *permitted* tool with that same name would raise a spurious collision error on a
  name nothing had actually claimed. Fixed by only recording a name as taken once
  registration actually succeeds.

### Deliberate simplifications

- **Permissions were built and fully tested but never turned on** for the live agent
  profile. Adding an `allow:` block immediately restricts what the running agent can
  do, and that felt like a decision to make deliberately rather than as a side effect
  of building the engine.

### Try yourself

- Turn permissions on — add an `allow:` block to the player task in the live
  settings file and watch the agent's tool surface actually shrink to it.

---

## Phase B — get visibility before optimizing further (done)

**Goal going in:** you can't fix what you can't see, and this was the single
highest-leverage phase — most later work depended on it.

### The stack decision

The original plan for a unified observability app called for Rails plus a React
frontend. Neither Rails nor the `sqlite3` gem were installed on this machine, and
both were unverified on Windows — standing up that whole toolchain from scratch for
what is fundamentally a log viewer felt like a disproportionate lift. I already had a
Sinatra+ERB app from week 1 that did half of this job (agent session logs); I
extended that instead, with plain page-refresh polling for "live" views rather than
a server-push protocol. Less impressive on paper, but it shipped the same day and
needed zero new dependencies.

### What got built

| Piece | File | What it does |
|---|---|---|
| `ManagerLog` | `mud_manager/lib/mud_manager/manager_log.rb` | One JSONL record per tool call the daemon executes — mode, tool, args, result, elapsed time, errors — wired into the dispatcher. |
| `TelnetLog` | `mud_manager/lib/mud_manager/telnet_log.rb` | Every raw byte crossing the socket, both directions, wired into the session's reader thread and its send path. The login password is redacted at the source, never logged. |
| Millisecond timestamps | `boukensha/lib/boukensha/logger.rb` | The session logger's timestamps gained millisecond resolution plus a monotonic clock reading, so "duration between commands" became meaningful instead of ±1-second-quantized. |
| Mud Monitor | `mud_monitor/` (new Sinatra app) | Session transcript (forked from the week 1 log viewer — cost/token breakdown came along for free), plus new manager-log and telnet-log pages, a per-entry timing gutter, and live badges with auto-refresh on anything actively being written. |

### Verified live

Drove a real `look` call against the live game through the actual daemon (not a fake),
confirmed a manager-log record and telnet-log chunks were written, and confirmed the
running Mud Monitor app rendered them correctly — including confirming the login
password never appears anywhere on the rendered telnet page.

### Real bugs this caught

- **A Windows file-handle bug.** My first version of the JSONL log writer held a file
  handle open across writes for efficiency. On Windows, a handle held open by one
  process blocks another process (or even the same process's own cleanup code) from
  deleting that file — which broke test cleanup in a way that had nothing to do with
  the logging logic itself. Fixed by switching to open-append-close on every single
  write. At the volumes this project runs at, the extra open/close is free, and it's
  a pattern I kept using for every log/journal file built afterward.
- **A path-depth bug** in the new app's directory defaults, caught not by a test but
  by the sessions page coming back empty against my own real session logs after I
  pointed the app at them. All the automated tests used explicit paths, which is
  exactly why none of them caught it — a good reminder that directory-default logic
  needs at least one check against a real file layout, not just mocks.

### Deliberate simplifications

- No live server-push (SSE) — pages that are "live" just auto-refresh on a timer.
- No cross-layer diffing between what the telnet log saw and what the manager log
  saw (i.e., "what did the agent's own drain-before-send logic silently throw away
  between commands") — a genuinely interesting question, just not one I answered here.

### Try yourself

- The three logs (sessions, manager, telnet) all use the same seq/timestamp shape —
  a diff view between the manager and telnet logs for one time window would show
  exactly what got discarded between commands, which is one of the more interesting
  unanswered questions from this phase.

---

## Phase C — fix the actual navigation problem (done)

**Goal going in:** replace slow, unreliable room inspection with something fast and
deterministic.

The obvious path here was an LLM-driven subagent that decides which MUD commands to
call and parses the result — I skipped building that entirely and went straight to a
deterministic version, on the theory that a fixed command sequence plus a pure-text
parser could do the same job with zero model calls. That turned out to be right.

### What got built

| Piece | File | What it does |
|---|---|---|
| `RoomParser` | `boukensha/lib/boukensha/tools/room_parser.rb` (later moved under `Mud::` in the next phase) | Pure text → Hash, no I/O. Splits the `inspect` composite's output into name, description, vitals, exit map, and mob/object lines — classified by their ANSI color, verified against real captures rather than assumed. |
| `RoomSurvey` | `boukensha/lib/boukensha/tools/room_survey.rb` | `poll` → `inspect` → classify → `consider`/`examine` per **distinct** mob (deduplicated, so three identical mobs cost one round-trip pair, not three) → a compact summary. Zero LLM calls anywhere in the sequence. |
| `inspect_room` native tool | wired at the agent entrypoint | Drives `RoomSurvey` through the same permission-gated dispatch path every other tool uses (Phase A's engine), so it's subject to the same `allow:` rules rather than being a special ungated case. |

### Real fixtures, not hand-written ones

I captured actual room text from the live game — including a genuine mob encounter
(a pit fiend, sitting in a stone circle) — and built the parser tests from those
captures rather than writing synthetic fixtures by hand. That paid off immediately:
the miss-message pattern I'd assumed the game would use when a `consider`/`examine`
target doesn't resolve turned out to be wrong for this specific server (`consider`
answers with *"Consider killing who?"*, `examine` answers with *"You do not see that
here."* — two different messages, neither of them what I'd guessed going in). Building
the miss-detection from what the server actually says, rather than porting an
assumption, is the whole reason this parses correctly.

### Verified live

Walked into the pit fiend's room through the actual wired-up native tool (not the
test fixtures) and got back:

```
mobs: The pit fiend is sitting here. (You ARE mad!; The pit fiend is in excellent condition.)
```

with zero LLM calls anywhere in the path.

### Deliberate simplifications

- **No ranked-candidate retry on a keyword miss.** The parser's keyword guesser
  returns one best guess; if `consider` says that keyword doesn't resolve, the mob is
  cached as permanently unresolved rather than retried with a second guess. Worth
  revisiting if misses turn out to be common in real play.
- **The look-candidates problem — detecting hidden, examinable nouns in room prose
  (a fountain, a statue, wall paintings) that the game never lists explicitly — was
  skipped entirely.** This is the one genuinely fuzzy piece of the whole survey; every
  other field is a mechanical parse, and this one isn't. Not attempted here.

### Try yourself

- If you want look-candidates, the room descriptions are already being parsed and
  stored — the missing piece is purely the noun-extraction/filtering layer on top,
  not any new plumbing.
- The keyword-miss cache is a plain in-memory Hash today; if you add the retry logic
  above, that's also the natural place to make the cache smarter (e.g. tracking *which*
  guesses were tried, not just pass/fail).

---

## Summary: what to actually do next

1. **Turn on permissions** (Phase A) — the engine is done and tested, just needs an
   `allow:` block.
2. **A telnet/manager diff view** (Phase B) — would answer "what does my own drain
   logic throw away between commands," which came up as an open question and never
   got resolved.
3. **Look-candidates** (Phase C) — the one deliberately-fuzzy field left unbuilt; the
   room-parsing plumbing it would sit on top of already exists.

Everything else from these three phases shipped as designed and is exercised by the
test suite plus the live verification runs noted above.
