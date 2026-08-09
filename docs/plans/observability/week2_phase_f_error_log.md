# Week 2 — Phase F: Deeper Observability

**Status: error log built; two items skipped.** Split out of the original
combined report so each phase has its own file. Previous:
[E — player tracking](week2_phase_e_player_tracking.md). Companion:
[`week2_catchup_plan.md`](week2_catchup_plan.md). Test totals: see the note
at the top of [Phase D's report](week2_phase_d_agent_memory.md) — D, E, and F
were built and tested together.

---

## Phase F — Deeper observability (error log only; two items skipped)

### What got built: agent error log

`Boukensha::ErrorLog` (`boukensha/lib/boukensha/error_log.rb`) — one JSONL line per
caught exception: class, message, first 20 backtrace frames, a free-form `context`
string. Off by default (`BOUKENSHA_ERROR_LOG`), now enabled on the live profile.

Two places actually use it:

1. **`Mud::Hooks`' internal rescues.** Every `rescue StandardError` in `before_tools`/
   `after_tool`/`before_model`/`scrape_vitals` used to just swallow the exception —
   correct behavior (a broken hook must degrade the agent to "no memory," never crash
   the turn), but with nowhere to see *that* it happened. Now it logs, still degrades
   the same way.
2. **A new top-level safety net in `Repl#run_turn`.** Before this, only `LoopError`
   and `ApiError` were caught there — anything else (a genuinely unexpected exception)
   propagated and **crashed the whole REPL process**, losing the conversation. Added a
   broad `rescue StandardError` after the specific ones, logging with a backtrace and
   printing a message that the session is still alive.

**Verified live** with a real triggered failure (a broken `call_tool` lambda inside
`Mud::Hooks#before_model`): the hook degraded silently as designed
(`context.state_block` stayed `nil`, no exception reached the caller) and the error
log captured the full exception with a real backtrace pointing at
`RoomSurvey#call` → `Mud::Hooks#survey_and_persist!` → `#resolve_room!` →
`#before_model`.

Mud Monitor gained an **Errors** page (`/errors`,
`mud_monitor/lib/mud_monitor/error_log_store.rb`), newest-first.

### What got skipped, and why

- **Work attribution** (operation IDs/parent IDs/nesting so hidden automatic work —
  room surveys, hook DB writes — is visually distinguishable in mud_monitor from
  model-selected tool calls). Real scope here is large — a full span/trace layer on
  top of everything Phase D already does. Out of remaining budget.
- **OpenTelemetry export.** I decided to skip this on the strength of a lesson I'd
  already taken to heart from earlier in this project: it's cheap to bolt on, but it
  doesn't actually answer "what is my loop doing" — it's useful for performance, not
  behavior, which isn't the problem I'm trying to solve right now. (Later revisited —
  see [`otel_integration_plan.md`](otel_integration_plan.md).)

### Try yourself

- If you ever *do* want work attribution, the error log's `context:` string convention
  (`"Mud::Hooks#before_model"`, `"Repl#run_turn"`) is a small step short of it — you
  already know *where* things run, just not nested timing.
- Consider rotating/pruning `error.log` if it ever gets used in anger — right now it's
  one flat file with no size cap, which is fine for a dev tool but not forever.
- **`plan_route`** — a read-only tool that searches the known room graph instead of the
  agent rediscovering paths one move at a time — is now the top item on the "what's
  next" list overall: the graph built in Phase D is complete enough and, via
  `/knowledge/map`, visible enough to make it worth building.

---

Previous: [Phase E — track the player](week2_phase_e_player_tracking.md). Full
run: [A](week2_phase_a_navigation.md) → [B](week2_phase_b_observability.md) →
[C](week2_phase_c_room_survey.md) → [D](week2_phase_d_agent_memory.md) →
[E](week2_phase_e_player_tracking.md) → F (this file).
