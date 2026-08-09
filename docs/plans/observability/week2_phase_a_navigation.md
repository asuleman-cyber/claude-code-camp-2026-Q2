# Week 2 — Phase A: Make Navigation Debuggable

**Status: done.** Split out of the original combined report so each phase has
its own file. Siblings: [B — observability](week2_phase_b_observability.md),
[C — room survey](week2_phase_c_room_survey.md),
[D — agent memory](week2_phase_d_agent_memory.md),
[E — player tracking](week2_phase_e_player_tracking.md),
[F — error log](week2_phase_f_error_log.md). Companion:
[`week2_catchup_plan.md`](week2_catchup_plan.md).

The overall roadmap — reset the world, see what the agent sees, replace slow
room inspection with something fast — was inspired by watching Andrew work
through the same problems in his own run at this camp. Everything below is my
own implementation, built against my own codebase, not a port of his.

**Test totals by the end of Phase C:** `boukensha` 64 runs / 189 assertions,
`mud_manager` 22 runs / 163 assertions — all green, verified live against
`localhost:4000` (current totals live in the Phase D report).

---

## Before Phase A: the foundation

Before any of the three phases below, `week2_observability/` needed a starting point. I
forked my own most-advanced week 1 work forward — my final-stage Ruby agent (the one
with full context management and MCP support) became `week2_observability/boukensha`, and
my own MUD client gem became `week2_observability/mud_manager`. Two things had to be fixed
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
| Reset script | `week2_observability/bin/reset` | Standalone Ruby script, no MCP daemon involved: logs in as the player (so there's a live target), logs in as admin, `goto`s the starting room, `trans`fers the player to it, quits both cleanly. |
| Composite `inspect` tool | `mud_manager/lib/mud_manager/mcp/dispatcher.rb` | `look` + `exits` in one MCP round trip instead of two separate tool calls. Tool count went from 26 to 27. |
| `Boukensha::Permissions` | `boukensha/lib/boukensha/permissions.rb` | A pure allowlist, default-deny gate — `tool(param: value|value2)` rule grammar, `*` for any value, bare rule names matching under any MCP prefix. Enforced in `Registry#tool`/`#dispatch`, the one place every registration path (MCP-derived and native) goes through. No `allow:` block on a task = fully permissive, so nothing changes unless a task opts in. |
| `week2_observability/bin/rebuild` | — | Rebuilds and reinstalls both gems from source. Uses `--ignore-dependencies` on install so the unmet TUI dependency (see above) doesn't block installing the other 95% of the gem. |

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

Next: [Phase B — get visibility before optimizing further →](week2_phase_b_observability.md)
