# Week 3 Technical Documentation

> **Status:** Phases G–J built and tested; **G, H and J verified live**
> against a real model and the real CircleMUD on 2026-08-09. **Phase I (the
> Navigator) was offered to the model twice and never called**, so it remains
> unvalidated. Per-phase detail lives in
> [`docs/plans/capability/`](../plans/capability/).

## Problems observed in Week 2

- The agent could play, but nothing in it could state what it was trying to
  achieve. Every turn started from the user's last sentence.
- Nothing ever checked whether play was still going anywhere. A turn that
  burned its whole iteration budget going in circles looked, from outside,
  exactly like one that made progress.
- Phase D built a room graph, and only one thing could read it: the state
  block for the room the agent was standing in. No role could ask about
  anywhere else.
- Everything learned died with the process. Restarting meant relearning that
  the pit fiend kills you.

## Technical Goal

Design an agentic loop capable of executing complex goals:

- **Plan decomposition** — a goal becomes an objective, concrete steps, and
  an observable stopping condition, before play begins.
- **Refined memory and knowledge access** — the accumulated world model
  becomes queryable by the roles that need it, and the character keeps a
  memory of its own experience across sessions.
- Do it by extending the Week 2 architecture (hooks, `Permissions`, the room
  store) rather than porting a parallel one alongside it.

## Technical Uncertainty

- Would splitting one agent into several roles actually improve play, or just
  multiply the cost of the same behaviour? Each extra role is a model call
  per turn with nothing guaranteed in return.
- Where does a plan have to live to survive a long session? Context
  compaction drops the oldest 40% of history the moment the window fills.
- Is an LLM subagent ever the right answer for navigation, when the room
  graph already supports an exact shortest-path query? Phase C had already
  deleted an LLM room-inspector in favour of a parser for that reason.
- What actually belongs in cross-session memory, given a world-state database
  already exists and answers a different question well?

## Technical Hypothesis

- An agent fails at complex goals mostly because nothing holds the goal
  between turns — not because it reasons badly turn to turn. Give the goal
  somewhere durable to live and much of the drift should stop.
- A checkpoint is only worth its cost if it can *disagree*. A Judge that
  never returns anything but `continue` is pure overhead.
- Specialised roles with genuinely narrow tool surfaces will beat one
  generalist, mostly because a narrow surface removes options rather than
  adds capability.
- Memory that is rewritten will stay useful; memory that is appended to will
  grow until nothing can afford to read it.

## Technical Observations

### 1. The plan had to go in the system prompt

`Context#compact_messages!` drops the oldest 40% of messages when the window
fills, so a plan delivered as a message is precisely what disappears
mid-session — leaving the agent playing on with no idea what it was for.
Moving it into the system prompt (composed on read by
`Context#effective_system`, never stored) made it uncompactable. Because
every backend already calls `context.system`, all five picked it up with no
per-backend code — the same trick `#messages` used for the Phase D state
block.

> A test fills a context, compacts it, and asserts the plan survived. That is
> the guarantee, not the comment.

### 2. A subagent must share the Player's MUD connection

`mud-manager --mcp` holds one telnet session with one logged-in character. A
subagent spawning its own server would be a second login *as the same
character* — not an isolated observer but a fight with itself over one
connection. So `register_mcp_servers` returns live clients and
`subagent_context` builds a throwaway Context over them: separate context,
shared connection.

### 3. Read-only was already built, and had never been switched on

Phase A's `Permissions` engine had been complete, tested, and unused since
Week 2. The Judge and Navigator are its first real callers. Expressing their
surfaces as allowlists rather than inventing the reference's `role:` field
meant one gate instead of two — and because `Permissions` filters at
*registration*, a denied tool isn't merely refused, it never exists.
Dispatching `tbamud__move` as the Navigator raises `UnknownToolError`.

### 4. A dead code path had rotted for two weeks

`Config::PROMPTS_DIR` had one `..` too many and had never resolved to a real
directory in any step since Week 1. The packaged `prompts/system.md` had
never once been read. It went unnoticed because the live `settings.yaml`
gives the player a `prompt_override`, so the fallback was never exercised.
Phase G surfaced it only because Planner and Judge have no override to be
rescued by — they booted with a nil system prompt and no error.

> A fallback that every real caller bypasses can rot indefinitely without a
> test going red. Worth looking for others.

### 5. The Navigator had to justify existing

Phase H's `route_to` is an exact BFS. An LLM wrapping it is a slower, less
reliable BFS unless it answers something BFS structurally cannot: a
destination that isn't a room name, "no route exists — now what?", or
ambiguity between matching rooms. That is written into `consult_navigator`'s
own description, so callers holding an exact room name are told to skip it.

### 6. Memory and world-state are different questions

`knowledge.sqlite3` answers "what is there?" — spatial, current, queryable.
Cross-session memory answers "what have I learned?" — narrative, historical,
prose. `Tasks::Chronicler` has zero tools specifically so it cannot drift
into the first job: `world_knowledge` already answers that live and for free,
and copying it into a digest only makes a staler second copy.

### 7. The live run: the Judge disagreed, and the Navigator was ignored

Two sessions, real MUD, `claude-haiku-4-5`, character `dummy`.

**The Judge disagreed.** Session 2's second turn hit `max_iterations`, the
Judge was invoked (a tripped limit is judged regardless of `every: 2`), and
returned `replan`. Every `VERDICT:` line parsed — no spurious `:flag` from
the fail-closed default. It also called `world_knowledge` unprompted, twice,
`kind=overview` then `kind=room`. The checkpoint hypothesis — that it is only
worth its cost if it can disagree — survived its first real test.

**Memory crossed the process boundary.** A digest written at session 1's EOF
was read back by session 2's Planner, and the Player's prompt contained the
resulting plan but not the memory. It merged rather than appended across two
rewrites: `Strategies` went from `_nothing yet_` to real content, the layout
gained a room, the open threads were rewritten rather than restated.

**The Navigator was never called.** `consult_navigator` was available to the
Player for both sessions and invoked zero times. Not a bug: every destination
was an adjacent room the state block already named, and the tool's own
description tells callers holding an exact room name to use the cheaper path.
It steered correctly — and in doing so left the phase with no evidence that
it works or that this agent wants it.

> A tool nobody calls is not automatically a failure, but it is not a
> success either. The case for the Navigator was that BFS cannot answer vague
> destinations; two sessions produced no vague destinations. Until one does,
> that case is an argument, not a finding.

**Cost:** $0.10 for both sessions — player $0.078, judge $0.013, chronicler
$0.007, planner $0.003. Orchestration is ~22% of spend at `every: 2`.

### 8. Two roles were invisible in the logs — and fixing it found a third bug

`run_planner` and `run_chronicler` call `Client#call` directly instead of
going through `Agent#run`, and `Logger#prompt` is only emitted inside
`Agent#run`. Their responses were logged and costed correctly; what they were
*given* was not recorded anywhere. Confirming the Planner had actually
received the memory digest required a separate script.

> The two roles whose entire behaviour is determined by their input were the
> two whose input wasn't logged.

Both now log their prompts, tagged with `task:` so a subagent's request is
distinguishable from the turn's real user input. Which is what exposed the
older bug underneath.

### 9. A synthetic message will eventually be mistaken for a real one

`Context#messages` appends the state block as a synthetic trailing **user**
message, and `Mud::Hooks#before_model` sets it *before* `Logger#prompt` runs.
So `messages.last` was the state block — and `mud_monitor`, taking `.last` as
the turn's user entry, had been rendering `[here] Poor Alley…` where the
human's instruction belonged. In every hooked session since Phase D. For two
weeks.

Nothing failed. The tests passed, the page rendered, the text looked
plausible — it *is* a real message the model really received. It was only
caught because the `task:` work put that parser branch under scrutiny, and
because checking the live output meant reading a transcript closely enough to
notice the first line was wrong.

> Two lessons, and the second is the uncomfortable one. A synthetic message
> that is indistinguishable in shape from a real one will eventually be
> treated as real — the fix was to stop making them indistinguishable
> (`synthetic_tail`), not to sharpen the guess. And a renderer nobody reads
> carefully can be wrong for months without a single test going red: every
> test asserted on data the parser produced, and none asserted that the data
> meant what it claimed.

**Still unknown:** whether the Chronicler over-forgets. Both rewrites here
grew the digest and dropped nothing important, which is the easy case; the
interesting one is a rewrite against a digest already at the character cap.

## Technical Conclusions

- **Three of the four roles earn their place; one has not shown that it
  does.** Planner, Judge and Chronicler all did something a single agent
  could not: hold an objective across turns, disagree with progress, and
  carry knowledge across a process boundary. The Navigator was available for
  two full sessions and never invoked.
- **The checkpoint hypothesis held.** A Judge that could only say `continue`
  would have been pure overhead; it returned `replan` on its first real
  opportunity, and it reached for `world_knowledge` to ground the judgement
  rather than assessing from the transcript alone.
- **Specialisation was mostly about removing options, not adding
  capability.** The Judge's value came from a read-only surface; the
  Navigator's from being unable to move; the Chronicler's from having no
  tools at all. In every case the constraint, not the capability, is what
  made the role trustworthy — and `Permissions`, built in Week 2 and never
  switched on, turned out to be the mechanism the whole week rested on.
- **Orchestration cost ~22% of spend** at `every: 2` and bought plan
  persistence, one course correction, and durable memory. That is a
  defensible ratio, and it is measurable per-role only because the `task:`
  field was threaded through the logger.
- **Reuse beat porting.** Phase D's room store, Phase A's permissions engine,
  and Phase C's `RunDSL#dispatch` seam carried all four phases. The one
  genuinely new thing was cross-session memory — the only gap Week 2's
  architecture had actually left open.

**What still isn't measured:** whether an orchestrated agent *plays better* —
survives longer, achieves more — than a single one. Two short sessions show
the machinery works, not that it wins. That needs a longer run with a goal
hard enough to fail at.

## Key Takeaway

**A plan is only as good as the place you put it.** The most consequential
decision of the week was not adding a Planner — it was noticing that a plan
stored as a message gets silently deleted by the compactor, and that the
system prompt is the only part of the context nothing evicts. The same shape
recurred three more times: the state block that must not accumulate, the
digest that must be rewritten rather than appended, the subagent context that
must not touch its caller's. In each case the design question was not "what
should this component do?" but "where does this survive, and what deletes
it?"

The live run added a second, less comfortable one. **Building a capability is
not the same as needing it.** The Navigator is the best-argued component of
the week — bounded, isolated, permission-gated, justified in writing against
a deterministic alternative — and the agent never once asked it anything. The
argument was sound and the thing may still be unnecessary. Two sessions is
not enough to conclude that, which is exactly why it is written down as an
open question rather than a feature.
