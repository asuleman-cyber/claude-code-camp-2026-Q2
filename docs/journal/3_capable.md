# Week 3 Technical Documentation

> **Status:** Phases G–J are built and tested; none has been verified live
> against a real model. Goal / Uncertainty / Hypothesis below are written
> from the design work and are final. **Observations and Conclusions are
> deliberately incomplete** — they need a live run, and filling them in from
> offline test results would be inventing evidence. Per-phase detail lives in
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

**Pending live verification.** Nothing above required a real model call. The
things that do, and are therefore still unknown:

- whether the Judge reliably emits a parseable `VERDICT:` line (the
  fail-closed default turns a sloppy prompt into spurious `:flag`s);
- whether it ever disagrees, or just says `continue`;
- whether the Navigator fabricates directions the tool never gave it;
- whether the Chronicler's instruction to *forget* causes it to over-forget,
  which would silently lose history with no error anywhere.

## Technical Conclusions

_Pending a live run. What can be said now:_

- **The plumbing holds.** Four roles, three restricted tool surfaces, a
  shared MUD connection, and a memory that survives a process boundary — all
  verified offline against real MCP servers, real SQLite, and real
  permissions. 263 boukensha tests, green.
- **Everything is off by default.** `Orchestrator.build` returns nil unless
  something is switched on, and a `settings.yaml` written before Week 3 runs
  byte-for-byte as it did. That was deliberate: four new model roles is a lot
  of new behaviour to inflict on a config that didn't ask for it.
- **Reuse beat porting.** Phase D's room store, Phase A's permissions engine,
  and Phase C's `RunDSL#dispatch` seam carried all four phases. The one thing
  genuinely new was cross-session memory — the only gap the Week 2
  architecture had left open.

_The conclusion that matters — whether an orchestrated agent plays better
than a single one — is exactly what has not been measured yet._

## Key Takeaway

_Provisional, pending live results._

**A plan is only as good as the place you put it.** The single most
consequential decision of the week was not adding a Planner — it was
noticing that a plan stored as a message gets silently deleted by the
compactor, and that the system prompt is the only part of the context nothing
evicts. The same shape recurred three more times: the state block that must
not accumulate, the digest that must be rewritten rather than appended, the
subagent context that must not touch its caller's. In each case the design
question was not "what should this component do?" but "where does this
survive, and what deletes it?"
