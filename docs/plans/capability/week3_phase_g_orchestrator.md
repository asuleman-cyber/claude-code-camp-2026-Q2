# Week 3 — Phase G: The Orchestrator (Planner + Judge)

**Status: built, tested, and verified live** against a real model and the
real CircleMUD — see [Verified live](#verified-live-2026-08-09) below.
Companion: [`capability_plan`](capability_plan). Previous week:
[Phase F — error log](../observability/week2_phase_f_error_log.md).

The agent could play. It could not say what it was trying to do, and nothing
ever checked whether it was still doing it. Phase G adds the two model roles
either side of the Player: a **Planner** that decides the objective before
play starts, and a **Judge** that checkpoints afterwards and returns
`continue` / `replan` / `flag`.

**Test totals after Phase G:** `boukensha` 177 runs / 525 assertions,
`mud_manager` 41 / 217, `mud_monitor` 71 / 249 — all green. Up from
150 / 399, 41 / 217, 66 / 229 at the Week 2 fork point.

---

## Setup — how `week3_capable/` came to exist

Forked from `week2_observability/` the same way that directory forked its own
sources (see `week2_observability/README.md`'s "Setup"): `boukensha/`,
`mud_manager/`, `mud_monitor/`, `observability/` and `bin/` copied across as
siblings, built gem artifacts (`*.gem`) left behind. Nothing in
`week2_observability/` was modified — it stays as the Week 2 record.

Every cross-package path was already relative (`boukensha/test/helper.rb`
reaches `mud_manager` via `../../mud_manager`; `mud_monitor` finds
`.boukensha/` four levels up), so the fork repointed itself and all three
suites were green before a line of Phase G was written. Only prose
references to `week2_observability/…` needed updating, plus one that
deliberately stays: `mud_monitor/README.md` still cites Week 2's README for
*why* the stack is Sinatra rather than Rails, because that is where the
decision was actually made.

---

## What got built

| Piece | File | What it does |
|---|---|---|
| `Context#plan` / `#effective_system` | `boukensha/lib/boukensha/context.rb` | The plan, folded into the system prompt on read. `#system` is now an alias of `#effective_system`, so all five backends pick it up with zero per-backend code. Raw prompt still available as `#base_system`. |
| `Agent#stop_reason` | `boukensha/lib/boukensha/agent.rb` | `:completed` / `:max_iterations` / `:max_tokens`, exposed to the *caller*. The same three values already reached the log; the orchestrator needs them in-process. |
| `Agent(task:)` | `boukensha/lib/boukensha/agent.rb` | Tags every `response` event with the task that produced it. `Logger#response` already had the field — until now there was only ever one task to put in it. |
| `Tasks::Planner` | `boukensha/lib/boukensha/tasks/planner.rb` | No tools at all. 600 output tokens. |
| `Tasks::Judge` | `boukensha/lib/boukensha/tasks/judge.rb` | `READ_ONLY_TOOLS` allowlist, `max_iterations: 5`, and `.parse_verdict`. |
| `Tasks::Base.enabled?` | `boukensha/lib/boukensha/tasks/base.rb` | Reads `tasks.<name>.enabled`; defaults to off. |
| Per-task default prompts | `boukensha/lib/boukensha/tasks/base.rb`, `boukensha/prompts/{planner,judge}/system.md` | `prompts/<task>/system.md`, falling back to the shared `prompts/system.md` — so `player` reads exactly the file it always did. |
| `Boukensha::Orchestrator` | `boukensha/lib/boukensha/orchestrator.rb` | `plan!`, `judge_due?`, `judge!`. `.build` returns **nil** when nothing is enabled. |
| `Boukensha.subagent_context` | `boukensha/lib/boukensha.rb` | Throwaway Context + Registry over an **already-connected** MCP client. |
| `Logger#orchestrator` | `boukensha/lib/boukensha/logger.rb` | One line per planner/judge decision, as its own `phase`. |
| REPL integration | `boukensha/lib/boukensha/repl.rb` | `plan_if_needed` before the turn, `judge_if_due` after; new `/plan` command. |
| Transcript colour coding | `mud_monitor/{lib/mud_monitor/session.rb,views/session.erb,public/style.css}` | Parses the `orchestrator` phase; left-border colour per role, red for a `flag`. |

## A real bug this phase surfaced

**`Config::PROMPTS_DIR` had one `..` too many, and had since Week 1.**

```ruby
PROMPTS_DIR = File.expand_path("../../../prompts", __dir__)   # was
PROMPTS_DIR = File.expand_path("../../prompts",    __dir__)   # now
```

From `lib/boukensha`, three `..` lands on the gem root's *parent* —
`week2_observability/prompts`, `week1_baseline/ruby/prompts` — neither of
which has ever existed. So the packaged `prompts/system.md` was never once
read, in any step, in either previous week.

It went unnoticed because `.boukensha/settings.yaml` sets the player's
`prompt_override.system: true` and supplies its own
`.boukensha/prompts/player/system.md`, which takes priority. The default was
dead code masked by an override that happened to be configured.

Phase G is what surfaced it: Planner and Judge have no user override to be
rescued by, so they booted with a **nil system prompt** and no error. Worth
remembering as a class of bug — a fallback path that is never exercised
because every real caller takes the override, so it can rot indefinitely
without a single test going red. Three regression tests now pin it
(`test_the_packaged_prompts_directory_actually_exists` and friends).

The player's behaviour is unchanged: its override still wins over its
default, exactly as before. `prompts/` was also added to the gemspec's
`spec.files`, which had likewise never included it.

## The decisions worth knowing about

### The plan lives in the system prompt, not in a message

This is the load-bearing choice of the phase. `Context#compact_messages!`
drops the oldest 40% of history the moment the window fills — so a plan
delivered as an ordinary user message is *exactly* the kind of thing that
silently disappears mid-session, leaving the agent playing on with no idea
what it was for. The system prompt is never compacted.

Composed on read (`effective_system`) rather than stored, so re-planning is a
plain assignment that cannot leave a stale copy behind. And because every
backend already calls `context.system` — Anthropic `system:`, Gemini
`systemInstruction`, OpenAI `instructions`, both Ollamas' leading system
message — aliasing `system` to the composed value means all five got this
with no per-backend plumbing at all. That is the same trick `#messages`
already used for `state_block` in Phase D; it worked there for the same
reason.

There is a test that fills a context, compacts it, and asserts the plan is
still in the prompt afterwards (`test_the_plan_survives_compaction`).

### The Judge shares the Player's MUD connection

`mud-manager --mcp` holds one telnet session with one logged-in character. A
subagent that spawned its own server would be a *second login as the same
character* — not an isolated observer, a fight with itself over one
connection.

So `register_mcp_servers` now returns the live client objects alongside the
counts (`[{name:, client:, prefix:, count:}]`, was `{name => count}`), and
`subagent_context` registers those same clients into a fresh Registry via the
`Tools::Mcp.register_client` seam that already existed for exactly this shape
of reuse. The Judge gets its own Context — nothing it says enters the
Player's history — over a shared connection.

### Read-only means Permissions, not a new `role:` field

The reference design expresses the Judge's surface as `role: inspector` on
each tool spec. This codebase's tool specs have no role concept, and adding
one would mean a second gate running beside the allowlist Phase A already
built, tested, and left switched off. So the read-only surface is
`Tasks::Judge::READ_ONLY_TOOLS` fed through `Permissions` — same guarantee,
one gate, enforced in `Registry#tool`/`#dispatch` like everything else. Phase
A's engine finally has a real caller.

It is a **code constant, not a settings.yaml `allow:` block**: "the Judge
cannot move the character" is a correctness property of the orchestrator, not
a preference a config edit should be able to switch off by accident.

Worth noting what the denial actually looks like: because `Permissions`
gates at *registration* as well as dispatch, a denied tool is never
registered, so calling it raises `UnknownToolError` — the Judge cannot even
see that `move` exists. Stronger than a dispatch-time refusal.

### Both failure paths fail closed, in opposite directions

- **A failing Planner returns nil and changes nothing.** The agent plays
  unplanned. Taking a working session down because an *optional* planning
  step 500'd would make the orchestrator strictly worse than not having one.
- **A failing or unreadable Judge returns `:flag`.** Never `:continue`. A
  checkpoint that fails open lets an unsupervised agent keep running
  precisely when its supervision broke. `parse_verdict` returns `:flag` for
  unparseable output for the same reason, and scans from the end so a verdict
  word used mid-sentence ("this isn't a replan situation") loses to the real
  trailing line.

### Off by default

`Orchestrator.build` returns `nil` unless `tasks.planner.enabled` or
`tasks.judge.enabled` is set, and every call site in the REPL is guarded, so
a `settings.yaml` written before Phase G produces byte-for-byte the loop it
produced before. Same posture as Step 12's compactor and Phase A's `allow:`
engine: ship it real, switch it on deliberately.

## Turning it on

```yaml
tasks:
  player:
    provider: anthropic
    model:    claude-haiku-4-5
  planner:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
  judge:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
    every:    3        # judge every 3rd player turn (default 1)
```

A turn that trips a limit is judged regardless of `every:` — being cut off
mid-task is the case a checkpoint exists for.

In the REPL: the plan prints once when written, `/plan` shows the plan in
force, a `:replan` verdict schedules a fresh plan for the next turn, and a
`:flag` prints the Judge's reasoning. `/clear` drops the plan along with the
history it was written for.

## Verified offline (before the live run)

Offline, with a real MCP server (`FakeMud`) and only the model call stubbed —
a script driving the real `Config`, `Registry`, `Permissions`, `Context`, and
`Logger`:

```
plan in system prompt:   true
base_system unpolluted:  true
compaction dropped:      12 messages
plan survived compact:   true
judge ctx is separate:   true
judge can look:          true
judge cannot move:       true
judge cannot send_raw:   true
player still can move:   true
judge look returned:     true          # read-only tool works on the live server
judge move refused:      true (UnknownToolError)
verdict parsed:          :continue
logged phases:           {"session_start"=>1, "plan"=>1, "orchestrator"=>1}
```

The `mud_monitor` view is covered end-to-end through the real ERB
(`app_test.rb#test_session_detail_renders_orchestrator_verdicts`), not just
at the parsing layer — a broken template would otherwise sail past
`session_test.rb`.

## Verified live (2026-08-09)

Two sessions against the real CircleMUD on `localhost:4000` with
`claude-haiku-4-5`, character `dummy`, run through the ordinary
`boukensha --no-tui` REPL with input piped in.

**The Planner produced a real plan**, in the shape its prompt asks for:

```
**Objective:** Establish current location and adjacent areas to inform future planning.
**Steps:** 1. Look around... 2. Move through one available exit... 3. Report back...
**Stop when:** The character has successfully moved to an adjacent room and
reported its contents, or when blocked by a locked door or hostile creature.
```

**The Judge disagreed** — the single most important result here. Session 2's
second turn hit `max_iterations`, the Judge was invoked (as designed: a
tripped limit is judged regardless of `every: 2`), and it returned:

```
judge/start    max_iterations
judge/verdict  replan
```

A checkpoint that can only ever say `continue` is pure overhead; the
hypothesis that it would be worth its cost only if it could disagree is the
one this run was really testing. It disagreed on its first real opportunity.
The `VERDICT:` line parsed cleanly both times it ran — no spurious `:flag`
from an unparseable reply, which was the specific prompt risk flagged
before the run.

**Per-task attribution worked**, straight out of `cost_breakdown`:

| task | cost (2 sessions) |
|---|---|
| player | $0.07774 |
| judge | $0.01265 |
| chronicler | $0.00672 |
| planner | $0.00287 |
| **total** | **$0.09999** |

Orchestration overhead is ~22% of spend. Worth knowing before turning
`every: 1` on.

### What this run also exposed — two logging bugs, both since fixed

**1. The Planner's and Chronicler's prompts were never logged.**
`run_planner` and `run_chronicler` call `Client#call` directly rather than
going through `Agent#run`, and `Logger#prompt` is only emitted inside
`Agent#run`. Their *responses* were logged correctly, so cost and output were
visible — but what they were *given* was not, which is an awkward gap for the
two roles whose entire behaviour is determined by their input. Verifying that
the Planner received the memory digest needed a separate script.

Fixed: both now log their prompt before the call, and `Logger#prompt` carries
a `task:` field so a subagent's request is distinguishable from the turn's
real user input. Confirmed against a live session:

```
prompt  task=planner            msgs=1  tools=0
prompt  task=player             msgs=2  tools=28
prompt  task=player             msgs=5  tools=28
prompt  task=chronicler         msgs=1  tools=0
```

**2. A pre-existing bug this uncovered: the state block was being rendered as
the user's input.** `Context#messages` appends the state block as a synthetic
trailing **user** message, and `Mud::Hooks#before_model` sets it *before*
`Logger#prompt` runs — so `messages.last` was the state block, not what
anyone typed. `mud_monitor` took `.last` as the turn's user entry, meaning
every hooked session since **Phase D (Week 2)** showed `[here] Poor Alley…`
where the human's instruction belonged.

This predates Phase G entirely — the pre-fix session logs from this same run
show it too — and was only noticed because the `task:` work put this exact
parser branch under scrutiny. Two things worth taking from it: a synthetic
message that is indistinguishable in shape from a real one will eventually be
mistaken for one, and a renderer nobody reads carefully can be wrong for
months without a test failing.

Fixed on both sides: `Logger#prompt` records `synthetic_tail`, and
`Session#turn_opening_message` skips it. Logs written before the flag existed
fall back to sniffing the `[here]` prefix, so existing session history renders
correctly too — verified against all three live logs, which now show
`"Look around, then move one room…"` rather than the state block.

## Not yet done

- **`Boukensha::Session.play`** — the fully autonomous outer loop (plan →
  N turns → judge → replan, no human). The plan named it as one option
  alongside "an equivalent wrapper around the existing `Repl`"; the REPL
  wrapper is what got built, because it keeps a human in the loop for the
  first outing of a component whose whole job is deciding when to stop.
- **Judge cost visibility.** `cost_breakdown` groups by `task`, so
  Planner/Judge/Player rows now separate for free in mud_monitor — but
  nothing yet warns when the checkpoint is costing more than the play.
- One behavioural change to note: the tool-use placeholder `response` event
  now carries `backend:`, so its `cost_usd` comes from the backend's own
  rates instead of mud_monitor's local `MODEL_PRICES` fallback. It was
  already being costed via that fallback; this makes it consistent with every
  other response event.

## Try yourself

- **Read the transcript** at `/sessions/:id` — the roles are colour-coded
  down the left edge, and a `flag` renders red.
- **Set `every: 1` and watch the cost breakdown.** Judging every turn roughly
  doubles the checkpoint spend; the measured baseline above is `every: 2` at
  ~13% of total for the Judge alone.
- **Find out whether the Judge ever says `flag`.** It returned `replan` on
  its first real opportunity, which is the good news; `flag` is the verdict
  that stops play for a human and it has not been seen in the wild yet.
