# Week 2 Technical Documentation

## Problems observed in Week 1
- No token/cost breakdown per request — couldn't tell how much of the budget tools vs. history vs. raw MUD text was eating.
- No per-tool latency — a slow MUD call and a slow model call looked identical from outside: "the turn took a while."
- No record of the actual request/response bytes — debugging meant re-running and hoping to reproduce, not reading back what happened.
- Nothing persisted across turns — every "why did it do that" question died with the process.
- Room inspection ran as an LLM ReAct loop for what's actually a deterministic parsing task, and there was no way to tell that from the outside without timing it.

## Technical Goal
- Make a bad run diagnosable — token/cost, per-tool timing, raw payloads — before touching the agent's reasoning at all.
- Do it with infrastructure that's provably working on this machine, not infrastructure the spec assumes is available.

## Technical Uncertainty
- Were the Week 1 "agent gets stuck" failures actual reasoning problems, or invisible plumbing (slow calls, dropped state, silent errors) wearing a reasoning-problem costume?
- Would a generic observability stack (OpenTelemetry, built for services) even answer agent-loop-shaped questions, or is that the wrong tool for turn-by-turn reasoning?
- Whether Rails + React, what the assignment spec calls for, was feasible here at all — hadn't confirmed either was installed.

## Technical Hypothesis
- If logs/timing/raw payloads go in before the reasoning gets touched, most of what currently reads as "the agent is dumb" will turn out to be ordinary bugs — missing data, a slow call, a silent failure.
- Observability has to come first, not get bolted on after capability work, or every "the agent got stuck" report stays a guess.

## Technical Observations

### 1. Repeatable resets
Needed every run to start from the same place before any of this data means anything.
- `bin/reset` — new admin-only primitives (`MudManager::Primitives#admin_goto`/`#admin_transfer`, never exposed as MCP tools on purpose) log in as admin and teleport the test player back to room 3001 (Temple Of Midgaard).
```sh
ADMIN_USERNAME=admin ADMIN_PASSWORD=password \
PLAYER_USERNAME=dummy PLAYER_PASSWORD=helloworld \
ruby week2_observability/bin/reset
```
> Can't tell if a fix worked if every run starts from a different room.

### 2. Composite `inspect` tool
- Collapsed `look` + `exits` into one MCP call (`mud_manager/lib/mud_manager/mcp/dispatcher.rb#dispatch_inspect`, tool count 26 → 27).
- Agent kept moving without checking exits when those were two separate calls — skipped the second one often enough that it mattered.

> One round trip removes the option to skip a step, which is more reliable than hoping the agent remembers to call both.

### 3. Permissions allowlist, built but not switched on
- `Boukensha::Permissions` — default-deny tool gate, wanted early.
- Left off in `.boukensha/settings.yaml` — no live data yet on which tools actually matter.

> Restrict based on evidence, not guesswork. Phase A tests: `mud_manager` 22/163, `boukensha` 50/133, all green.

### 4. Sinatra over the spec's Rails+React
- Spec calls for Rails + React. Neither Rails nor the `sqlite3` gem is installed or tested on this box.
- Forked `week1_baseline/log_viz` (Sinatra+ERB, already working) into `mud_monitor` instead of standing up an unproven stack from scratch.
- Swapped SSE for meta-refresh polling — didn't want to debug a websocket layer on top of everything else this week.

> Not elegant. Shipped same day because it was already proven.

### 5. ManagerLog + TelnetLog
- `ManagerLog` — one record per tool call: name, args, elapsed time, error. First time slow calls were visible instead of guessed at.
- `TelnetLog` — every raw byte, both directions. Password redacted at the source (`send_command(password, redact: true)`), verified by a test that greps the log file for the literal password.
- Both off by default, daily-rotated JSONL.
- Bumped `boukensha/lib/boukensha/logger.rb` to millisecond timestamps (`iso8601(3)` + `mono_ms`) — second resolution couldn't order two events inside the same turn.

> The moment per-tool elapsed time existed, "the agent is being weird" stopped being one bucket — some of it was still the agent, some of it was an 11-second MUD call nobody had ever measured. Phase B tests: `mud_manager` 34/203, `boukensha` 50/133, `mud_monitor` 26/69, verified live against real CircleMUD, not just `FakeMud`.

### 6. Deterministic room parsing
- Room inspection was visibly the slow part once logging existed, and it was running as an LLM ReAct loop for a task with no real judgment calls in it.
- `room_parser.rb` — pure text → Hash, zero I/O, classifies mobs vs. objects off ANSI color: yellow (`\e[0;33m`) mob, green (`\e[0;32m`) object, verified against tbaMUD source and this server's own captures.
- `room_survey.rb` — poll → inspect → classify → dedupe → summarize, zero LLM calls in the hot path.

> A "confused agent" symptom was sometimes just an LLM doing parsing work that was never actually ambiguous.

### 7. The reference plan didn't match this server
- Source plan assumed the "not here" miss-response was `"They aren't here."`
- This server actually says `"Consider killing who?"` / `"You do not see that here."` depending on the verb — didn't match, had to go verify against the real server instead of trusting the doc.

> Reference docs describe intent, not this server's actual strings. Tests came from real captures, including a pit-fiend room ("The Circle Of Stones") kept specifically because its formatting is ambiguous enough to be a real test. `boukensha` at 64 runs / 189 assertions after this phase.

### 8. `inspect_room` shipped, then got deleted
- Skipped the source plan's ranked-candidate retry-on-miss logic (§3.4) — `guess_keyword` returns one best guess and caches a miss as unresolved. Haven't checked whether that's a problem once there's more play data.
- The `inspect_room` native tool built on top of this doesn't exist anymore — deleted in Phase D once `Mud::Hooks` made calling it explicitly redundant.

> Visibility surfaces work that's now dead weight as clearly as it surfaces bugs.

### 9. OpenTelemetry infra
- docker-compose stack: Collector, Jaeger, Tempo, Grafana, four profiles (`debug`/`jaeger`/`tempo`/`compare`), everything bound to `127.0.0.1`, no auth, dev-only.
- Wired through `boukensha/lib/boukensha/telemetry.rb` + `noop.rb`/`open_telemetry.rb`, off by default, toggled via `~/.boukensha/settings.yaml`'s `observability.otel.*` or `BOUKENSHA_OTEL_*`.
- Pinned to OTel's GenAI semantic conventions (1.37.0) instead of inventing attribute names. Secrets redacted before touching a span; `reasoning` phases record presence only, never content.

> Adapted from the course reference material at `claude-code-camp-2026-Q2-main/week2_observability/` (approved for direct reuse), restructured because this codebase's `Logger`/`Agent` has no frame/span-stack architecture the way the reference does.

### 10. Flat span vs. waterfall
- First version: one span per turn. Wired up correctly, almost useless — renders as a single flat bar in Jaeger.
- Added `boukensha.model_call` / `boukensha.tool_call` as nested child spans under `boukensha.turn`.
- On a live run: two hanging MUD-login tool calls showed as two distinct ~11.5s bars inside a 77-second turn, next to ~1-3s model-call bars.

> Not something the flat span, or the JSONL transcript, makes obvious on its own.

### 11. Caught a real bug verifying it live
- Against a fake backend: caught the easy stuff — attribute cleaning, redaction logic.
- Against a real run (real MUD, real Anthropic key): `trace_id` wasn't landing in the JSONL. Installed gem was stale, missing the `current_ids` fix, because source got edited and `bin/rebuild` didn't get run.

> Verifying against source isn't enough when the runtime loads the installed/built gem, not the working tree.

**Scope note:** once state was observable, the agent obviously needed to *remember* what it saw — state-block injection, a SQLite knowledge store, player tracking, an error log. That's real, already underway, and Week 3 "capable" territory — going in `3_capable.md`, not padded in here. One judgment call from that work belongs in this entry: considered extending OTel to attribute hidden/hook-triggered work as its own span layer, decided against it — cheap to add, but it answers "how long did this take," not "what is my loop actually doing," which is a different question than the one this week was solving.

## Technical Conclusions
- Most Week 1 "reasoning failures" were plumbing: a skippable step, an unmeasured slow call, a forgotten rebuild.
- Deterministic parsing beat an LLM subagent for room-text classification — wasn't ambiguous to begin with, and now it's testable against fixed captures.
- Every infra choice that shipped same-day was the boring, already-proven option: Sinatra over untested Rails/React, meta-refresh over SSE, nested spans over a custom trace UI.
- OpenTelemetry earns its keep for exactly one question — where did the time go — and stops being useful past that.
- Instrumentation deleted a tool (`inspect_room`) as directly as it fixed a bug — both are real outcomes of the same visibility.

## Key Takeaway
- **Observability was the actual unlock, not a detour.** Nearly every real fix this week came from seeing a specific slow call, a specific skipped step, a specific stale build — not from reasoning harder about agent behavior.
- **Reference docs describe intent, not the live server.** The miss-response mismatch and the OTel adaptation both required checking the real system instead of trusting the plan that described it.
- **Verify against a live run, not just source.** The stale-gem bug only showed up once tested against the real MUD with a real key — fixture/fake-backend testing alone would have missed it.
- **Boring, already-proven infra wins under time pressure.** Every same-day ship this week reused something already working elsewhere in the repo instead of standing up something new and unverified.
- **Know where the tool stops answering your question.** OTel answers "how long," not "why" — recognizing that boundary early kept this week from turning into an open-ended tracing project.
