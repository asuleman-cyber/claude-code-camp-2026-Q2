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

## Phases H–J

Not started. See [`docs/plans/capability_plan`](../docs/plans/capability_plan):
H (knowledge as a query API), I (Navigator subagent), J (cross-session
character memory).
