# Week 3 — Capable

Making the agent capable of executing complex goals: plan decomposition,
richer knowledge access, navigation, and memory. The rollup plan is
[`docs/plans/capability_plan`](../docs/plans/capability_plan); each phase gets
its own write-up under [`docs/plans/capability/`](../docs/plans/capability/).

## Setup

This folder was forked from `week2_observability/` the same way that folder
forked its own sources — see
[`week2_observability/README.md`](../week2_observability/README.md)'s "Setup"
section for the pattern:

- `boukensha/`     ← `week2_observability/boukensha` (v0.12.0, Phases A–F + OTel)
- `mud_manager/`   ← `week2_observability/mud_manager`
- `mud_monitor/`   ← `week2_observability/mud_monitor`
- `observability/` ← `week2_observability/observability` (unchanged)
- `bin/`           ← `week2_observability/bin`

Built gem artifacts (`*.gem`) were deliberately not copied. Nothing in
`week2_observability/` was modified — it stays as the Week 2 record.

Every cross-package path was already relative, so the fork repointed itself:
`boukensha/test/helper.rb` reaches `mud_manager` via `../../mud_manager`, and
`mud_monitor` finds the repo-root `.boukensha/` four levels up. All three
suites were green in the fork before any Week 3 code was written
(`boukensha` 150/399, `mud_manager` 41/217, `mud_monitor` 66/229). Only prose
references needed updating.

Phase lettering continues from Week 2, which used A–F.

## Phase G — orchestrator: Planner + Judge (built; not yet verified live)

Full write-up:
[`docs/plans/capability/week3_phase_g_orchestrator.md`](../docs/plans/capability/week3_phase_g_orchestrator.md).

The agent could play, but it could not say what it was trying to do, and
nothing checked whether it was still doing it. Phase G adds the two model
roles either side of the Player:

- **`Tasks::Planner`** (`boukensha/lib/boukensha/tasks/planner.rb`) — no
  tools at all, by design. One model call, no loop. Writes an objective, 2–5
  concrete steps, and an observable "stop when" condition.
- **`Tasks::Judge`** (`boukensha/lib/boukensha/tasks/judge.rb`) — observation
  tools only, `max_iterations: 5`. Ends with `VERDICT: continue|replan|flag`.
- **`Boukensha::Orchestrator`** (`boukensha/lib/boukensha/orchestrator.rb`) —
  drives both around the Player's turn and holds the current plan/verdict.

Three things are worth knowing without reading the full write-up:

1. **The plan lives in the system prompt**, composed on read by
   `Context#effective_system`. `compact_messages!` drops the oldest 40% of
   history when the window fills, so a plan sent as a message is exactly what
   goes missing mid-session. There is a test that compacts a full context and
   asserts the plan survived.

2. **The Judge shares the Player's MCP connection.** `mud-manager --mcp`
   holds one telnet session with one character; a subagent spawning its own
   server would be a second login as the same character. So
   `register_mcp_servers` now returns live clients and
   `Boukensha.subagent_context` builds a throwaway Context+Registry over
   them.

3. **Read-only is enforced by Phase A's `Permissions`**, not a new mechanism
   — `Tasks::Judge::READ_ONLY_TOOLS` as a code constant, not a settings
   block, because "the Judge cannot move the character" is a correctness
   property rather than a preference. Denied tools are never registered, so
   the Judge cannot even see that `move` exists.

Failures fail closed in opposite directions: a broken Planner returns nil and
the agent plays unplanned; a broken or unreadable Judge returns `:flag`,
never `:continue`.

### Turning it on

Off by default — `Orchestrator.build` returns `nil` unless switched on, and a
`settings.yaml` written before Phase G runs exactly as it did before.

```yaml
tasks:
  planner:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
  judge:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
    every:    3        # judge every 3rd turn (default 1); a tripped
                       # limit is always judged regardless
```

In the REPL: the plan prints when written, `/plan` shows the plan in force, a
`:replan` verdict schedules a fresh plan for the next turn, `:flag` prints
the Judge's reasoning, and `/clear` drops the plan with the history it was
written for.

In `mud_monitor`, the three roles are colour-coded down the left edge of the
transcript (green Planner / amber Judge / blue Player) and a `flag` renders
red. `cost_breakdown` already grouped by task, so per-role cost separates for
free.

**Tests:** `boukensha` 177 runs / 525 assertions, `mud_manager` 41 / 217,
`mud_monitor` 71 / 249 — all green.

**Not yet verified live.** The plumbing is proven offline against a real MCP
server with the model call stubbed; no actual Planner or Judge API call has
been made yet, so the two `prompts/*/system.md` files are still untested
drafts. See the write-up's "Not yet done".

## Phase H — knowledge as a query API (built; not yet verified live)

Full write-up:
[`docs/plans/capability/week3_phase_h_knowledge.md`](../docs/plans/capability/week3_phase_h_knowledge.md).

Phase D's room graph only ever came back out as the *current* room's state
block. Phase H adds the ask side: a `world_knowledge` native tool
(`boukensha/lib/boukensha/mud/knowledge_tool.rb`) with three modes —

- `kind=overview` — how much of the world is known, and where the character is
- `kind=room, name=X` — that room's description, exits (with `(unexplored)`
  frontiers marked), and what has been seen there
- `kind=route, to=X` — the shortest **already-walked** route from here

backed by three new read-only `Store` methods: `route_to` (BFS over
`room_exits`), `all_exits`, and `find_rooms_by_name`.

Two things worth knowing:

1. **No second process.** The reference moved this to a separate
   `log_viz --mcp` server; here the loader hands the orchestrator the *same*
   `Store` instance `Mud::Hooks` writes through, so a subagent reads exactly
   what was just written — no subprocess, no handshake, no second handle on
   a database this process already has open.

2. **An unwalked exit is never part of a route.** `route_to` only follows
   edges with `target_room_id` set, which Phase D leaves NULL until the agent
   has actually stood in the destination. So it answers "can I get there by a
   route I know?", not "does a path exist?" Frontiers still *show* in a room
   lookup, marked `(unexplored)` — that is what makes "where next?" a
   decision rather than a guess.

The Player deliberately gets none of this (its knowledge already arrives in
the state block; a tool to re-ask would undo Phase D's zero-call revisits),
and so does the Planner — Phase G made it toolless on purpose. Today it is
the Judge's tool; Phase I's Navigator is the next caller.

**Tests:** `boukensha` 210 runs / 606 assertions, `mud_manager` 41 / 217,
`mud_monitor` 71 / 249 — all green.

## Phase I — Navigator subagent (built; not yet verified live)

Full write-up:
[`docs/plans/capability/week3_phase_i_navigator.md`](../docs/plans/capability/week3_phase_i_navigator.md).

A bounded, read-only subagent in front of Phase H's map, exposed to callers
as one tool: `consult_navigator(to:, from:)`.

**Why an LLM at all, when Phase H's BFS is exact?** It only earns the call
where BFS structurally can't answer: a destination that isn't a room name
("a shop", "back where the guard was"), *no* route existing (the useful reply
is then the nearest unexplored exit heading that way, not "no"), or several
rooms matching. Where the caller has an exact room name and a route exists,
`world_knowledge(kind: route)` is cheaper and identical — and the tool's own
description says so.

- **`Tasks::Navigator`** (`boukensha/lib/boukensha/tasks/navigator.rb`) —
  `max_iterations: 4`, and an allowlist of exactly `world_knowledge`.
- It **cannot move or look**, enforced by Phase A's `Permissions` rather than
  by convention: its registry contains one tool, and dispatching
  `tbamud__move` raises `UnknownToolError`.
- Isolated: its own Context, so the caller's history gains exactly one
  tool_call/tool_result pair and none of the intermediate map reads.

Registered on the **Player** (the primary caller — it is the one that moves,
and routing is the one thing the state block can't tell it) and the **Judge**
(to check a plan's geography). Not the Planner, which stays toolless.

Enabling it needs both `tasks.navigator.enabled: true` *and* a knowledge
store — without one its only tool doesn't exist, so it would be a model call
guaranteed to answer "I don't know".

```yaml
tasks:
  navigator:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
```

**Tests:** `boukensha` 225 runs / 651 assertions, `mud_manager` 41 / 217,
`mud_monitor` 72 / 254 — all green.

## Phase J — cross-session character memory (built; not yet verified live)

Full write-up:
[`docs/plans/capability/week3_phase_j_memory.md`](../docs/plans/capability/week3_phase_j_memory.md).

Everything the agent knew died with the process. `knowledge.sqlite3` kept
where the *rooms* are, but not that a pit fiend killed this character at
level 3, or what it was halfway through when the session ended.

- **`PlayerMemory`** (`boukensha/lib/boukensha/player_memory.rb`) — two files
  per character under `<config>/memory/`: `<name>.jsonl` (append-only
  history, never rewritten) and `<name>.md` (a bounded prose digest,
  rewritten wholesale). The digest stays affordable to read every session
  *because* it's rewritten rather than appended to.
- **`Tasks::Chronicler`** — **zero tools, by design.** `world_knowledge`
  already answers "what is there?" live; copying that into prose just makes a
  staler second copy. What belongs here is what no tool can answer — what was
  tried, what it cost, what to do differently. Writes under four fixed
  headings: Discoveries / Mistakes / Strategies / Open threads.

Two things worth knowing:

1. **Memory reaches the Player only through the Planner.** It goes into
   `run_planner`, becomes a plan, and arrives exactly the way Phase G already
   delivered plans. That costs one call's tokens at a decision point instead
   of riding on every iteration of every turn, and leaves the already-tested
   Player path untouched. A test asserts the digest never appears in the
   Player's context or prompt.

2. **Every write is open-append-close** — a documented Windows bug in this
   project (Phase B's logger, caught in Phase D), where a held handle blocks
   another process from deleting the file. A test removes the tmpdir
   afterwards and fails if that regresses.

Flushes at `/clear` (before wiping, so it doesn't record an empty session
over a real one), `/exit`, EOF, and any Judge verdict that isn't `continue` —
so a session killed mid-play still leaves memory behind. Repeated boundaries
don't pay twice.

```yaml
memory:
  enabled: true
  # character: Gandalf   # defaults to mcp_servers.mud.env.MUD_NAME
```

**Tests:** `boukensha` 263 runs / 746 assertions, `mud_manager` 41 / 217,
`mud_monitor` 73 / 259 — all green.

## Status

Phases G–J are all built and tested; **none has been verified live against a
real model yet.** The plumbing is proven offline against real MCP servers,
real SQLite, and real permissions — the prompts are untested drafts. See each
phase's "Not yet done" section; the autonomous `Session.play` loop from
Phase G also remains open.
