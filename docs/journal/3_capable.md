# Week 3 Technical Documentation

## Problems observed in Week 2
- The agent could play, but nothing in it could state what it was trying to achieve — every turn started from the user's last sentence.
- Nothing ever checked whether play was still going anywhere. A turn that burned its whole iteration budget going in circles looked identical from outside to one that made progress.
- Phase D built a room graph and exactly one thing could read it: the state block for the room the agent was standing in. No role could ask about anywhere else.
- Everything learned died with the process. Restarting meant relearning that the pit fiend kills you.
- `Boukensha::Permissions` had been built, tested, and left switched off since Phase A — no task had ever needed a restricted tool surface.

## Technical Goal
- Design an agentic loop capable of executing complex goals: plan decomposition, refined memory and knowledge access.
- Extend the Week 2 architecture (hooks, `Permissions`, the room store) rather than standing a parallel one up beside it.
- Ship every new role off by default — a `settings.yaml` written before Week 3 must run byte-for-byte as it did.

## Technical Uncertainty
- Would splitting one agent into several roles improve play, or just multiply the cost of the same behaviour? Each extra role is a model call per turn with nothing guaranteed in return.
- Where does a plan have to live to survive a long session, given compaction drops the oldest 40% of history the moment the window fills?
- Is an LLM subagent ever right for navigation, when the room graph already supports an exact shortest-path query? Phase C had already deleted an LLM room-inspector in favour of a parser for that reason.
- What belongs in cross-session memory, given `knowledge.sqlite3` already answers a different question well?

## Technical Hypothesis
- An agent fails at complex goals mostly because nothing holds the goal between turns, not because it reasons badly turn to turn.
- A checkpoint is only worth its cost if it can *disagree*. A Judge that never returns anything but `continue` is pure overhead.
- Specialised roles with narrow tool surfaces beat one generalist — mostly because a narrow surface removes options rather than adds capability.
- Memory that is rewritten stays useful; memory that is appended to grows until nothing can afford to read it.

## Technical Observations
### 1. The plan had to live in the system prompt
- `Context#compact_messages!` drops the oldest 40% of messages when the window fills — a plan delivered as a message is exactly what disappears mid-session.
- `Context#effective_system` composes it on read, never stores it, so re-planning is a plain assignment that can't leave a stale copy behind.
- `#system` aliased to the composed value, so all five backends picked it up with zero per-backend code — same trick `#messages` already used for the Phase D state block.

> Test fills a context, compacts it, asserts the plan is still in the prompt. That's the guarantee, not the comment.

### 2. Subagents share the Player's MUD connection
- `mud-manager --mcp` holds one telnet session with one logged-in character. A subagent spawning its own server is a second login *as the same character*.
- `register_mcp_servers` return shape changed (`{name => count}` → `[{name:, client:, prefix:, count:}]`) so live clients survive; `subagent_context` builds a throwaway `Context` over them.

> Separate context, shared connection. The isolation that matters is history, not sockets.

### 3. Read-only meant Permissions, not a new mechanism
- The reference design expresses the Judge's surface as `role: inspector` on each tool spec. This codebase's specs have no role concept.
- Adding one meant a second gate beside Phase A's allowlist. Used `Tasks::Judge::READ_ONLY_TOOLS` fed through `Permissions` instead — one gate, enforced in `Registry#tool`/`#dispatch` like everything else.
- Because `Permissions` filters at *registration*, a denied tool is never registered: dispatching `tbamud__move` as the Navigator raises `UnknownToolError`.

> Phase A's engine finally has a real caller. Denied isn't refused — it's invisible.

### 4. A dead code path had rotted since Week 1
- `Config::PROMPTS_DIR` was `../../../prompts` — one `..` too many, landing on the gem root's *parent*. `week2_observability/prompts`, `week1_baseline/ruby/prompts`: neither ever existed.
- So the packaged `prompts/system.md` had never once been read, in any step, in either previous week.
- Unnoticed because `.boukensha/settings.yaml` sets the player's `prompt_override.system: true` and supplies its own file, which wins.
- Surfaced only because Planner and Judge have no override to be rescued by — they booted with a nil system prompt and no error.

> A fallback every real caller bypasses can rot indefinitely without a test going red. Three regression tests now pin it.

### 5. Knowledge became queryable instead of only injected
- Added `Store#route_to` (BFS over `room_exits`), `#all_exits`, `#find_rooms_by_name`; surfaced as one `world_knowledge` tool with `kind=overview|room|route`.
- Did **not** stand up a second MCP server the way the reference did — the store is already open in-process, so the loader hands the orchestrator the same `Store` instance `Mud::Hooks` writes through.
- `route_to` walks only edges where `target_room_id IS NOT NULL`, which is exactly "edges actually walked". A frontier is shown, marked `(unexplored)`, but can never appear inside a route.

> "Can I get there by a route I know?" is a different question from "does a path exist?", and only the first one is safe to plan on.

### 6. The Navigator had to justify existing — then never got called
- `route_to` is already exact and deterministic. An LLM wrapping it is a slower, less reliable BFS unless it answers what BFS can't: a destination that isn't a room name, no route existing, or several rooms matching.
- Wrote that into `consult_navigator`'s own description, so callers holding an exact room name are told to use the cheaper path.
- Live: available to the Player for two full sessions, called **zero** times. Every destination was an adjacent room the state block already named.

> The tool description steered correctly — that's the design working, not the Player ignoring it. But it leaves the phase's justification an argument, not a finding. Two sessions produced none of the cases it exists for.

### 7. Memory is a different question from world state
- `knowledge.sqlite3` answers "what is there?" — spatial, current, queryable. `PlayerMemory` answers "what have I learned?" — narrative, historical, prose.
- `Tasks::Chronicler` gets **zero tools** by design: `world_knowledge` already answers the first question live and accurately, so a Chronicler with tools writes a staler second copy.
- `<name>.jsonl` append-only history + `<name>.md` rewritten wholesale. Open-append-close everywhere — a held handle blocks deletion on Windows, the Phase B/D bug.
- Memory reaches the Player *only* through the Planner. Its own prompt and context are untouched.

> The digest stays affordable to read every session because it is rewritten, not appended to. Forgetting is part of the job.

### 8. Live run — the Judge disagreed
Two sessions, real CircleMUD on `localhost:4000`, `claude-haiku-4-5`, character `dummy`.

- Session 2's second turn hit `max_iterations`; the Judge was invoked (a tripped limit is judged regardless of `every: 2`) and returned `replan`. Every `VERDICT:` line parsed — no spurious `:flag` from the fail-closed default.
- Judge called `world_knowledge` unprompted, twice: `kind=overview`, then `kind=room` on the room the plan was about.
- Map built during play: 4 rooms, 5 walked edges, 7 frontiers, with `x2`/`x3` revisit counts confirming Phase D's zero-round-trip known-room path still fires.
- Memory crossed the process boundary — session 1's digest read back by session 2's Planner; Player's prompt had the plan, not the memory. Merged rather than appended across two rewrites (1039 → 1324 chars, `Strategies` went from `_nothing yet_` to real content).
- Cost: **$0.09999** both sessions — player $0.078, judge $0.013, chronicler $0.007, planner $0.003. Orchestration ~22% of spend at `every: 2`.

> The checkpoint hypothesis survived its first real test. `kind=route` and the `:flag` verdict have still never fired in the wild.

### 9. Two logging bugs, and the second was older than this week
- `run_planner`/`run_chronicler` call `Client#call` directly, and `Logger#prompt` only fires inside `Agent#run` — so the two roles whose behaviour is entirely determined by their input were the two whose input never reached the log. Confirming the Planner got the memory digest needed a separate script.
- Fixing that meant tagging prompts with `task:`, which put `mud_monitor`'s `when "prompt"` branch under scrutiny — and exposed the older one.
- `Context#messages` appends the state block as a synthetic trailing **user** message, and `Mud::Hooks#before_model` sets it *before* `Logger#prompt` runs. So `messages.last` was the state block, and the viewer took `.last` as the turn's user entry.
- Every hooked session since **Phase D** rendered `[here] Poor Alley…` where the human's instruction belonged. Nothing failed — it *is* a real message the model really received.
- Fixed both: `synthetic_tail` on the prompt event, parser skips it, `[here]`-prefix fallback so existing logs render correctly too.

> A synthetic message indistinguishable in shape from a real one will eventually be treated as real — the fix was to stop making them indistinguishable, not to sharpen the guess. And every test asserted on data the parser produced; none asserted the data meant what it claimed.

**Scope note:** `Boukensha::Session.play` — the fully autonomous outer loop — was specified and not built. The plan offered it *or* a wrapper around the existing `Repl`, and the REPL wrapper shipped: a component whose whole job is deciding when to stop should keep a human in the loop on its first outing. Still open. So is whether the Chronicler over-forgets; both rewrites observed grew the digest and dropped nothing important, which is the easy case.

## Technical Conclusions
- Three of four roles earned their place — Planner, Judge, Chronicler each did something one agent couldn't. The Navigator was offered twice and never invoked.
- Specialisation was about removing options, not adding capability: read-only Judge, immobile Navigator, toolless Chronicler. The constraint is what made each trustworthy.
- `Permissions` — built Week 2, never switched on — turned out to be what the whole week rested on. Three of four roles are defined by their allowlist.
- Where a thing survives mattered more than what it does: plan in the system prompt, state block never stored, digest rewritten not appended, subagent context never touching its caller's.
- Orchestration cost ~22% of spend for plan persistence, one course correction, and durable memory — and was only measurable per-role because `task:` got threaded through the logger.
- Reuse beat porting: Phase D's store, Phase A's permissions, Phase C's `RunDSL#dispatch` carried all four phases. Cross-session memory was the only genuinely new thing.
- Two short sessions show the machinery works, not that it wins. Whether an orchestrated agent *plays better* is still unmeasured.

## Key Takeaway
- **A plan is only as good as the place you put it.** The most consequential decision of the week wasn't adding a Planner it was noticing that a plan stored as a message gets silently deleted by the compactor, and that the system prompt is the only part of the context nothing evicts.
- **Building a capability is not the same as needing it.** The Navigator is the best-argued component of the week, bounded, isolated, permission-gated, justified in writing against a deterministic alternative — and the agent never once asked it anything. The argument was sound and the thing may still be unnecessary.
- **A checkpoint is only worth its cost if it can disagree.** The Judge returned `replan` on its first real opportunity. Had it only ever said `continue`, ~13% of spend would have bought nothing.
- **Constraints, not capabilities, made the roles trustworthy.** Every role that worked was defined by what it couldn't do, and the gate enforcing that had been sitting unused since Week 2.
- **A wrong renderer can be right-looking for months.** The state block rendered as user input since Phase D, through every test suite, because the data was real but just not what it was labelled. Tests asserted the parser's output, never its meaning.
