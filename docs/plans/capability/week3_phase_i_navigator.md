# Week 3 — Phase I: The Navigator Subagent

**Status: built and tested; not yet verified live against a real model.**
Companion: [`capability_plan`](../capability_plan). Previous:
[H — knowledge query API](week3_phase_h_knowledge.md).

Phase H gave every non-Player role a way to query the map. Phase I puts a
bounded subagent in front of it, exposed to callers as a single tool:
`consult_navigator(to:, from:)`.

**Test totals after Phase I:** `boukensha` 225 runs / 651 assertions,
`mud_manager` 41 / 217, `mud_monitor` 72 / 254 — all green. Up from
210 / 606 and 71 / 249 at the end of Phase H.

---

## The question this phase has to answer first

`world_knowledge(kind: route)` already returns the shortest walked path,
**deterministically and exactly**. This project has a stated preference for
deterministic over LLM in precisely this situation — Phase C deleted an
LLM-driven room-inspector loop in favour of a parser for that reason. So an
LLM subagent wrapping a BFS needs to justify itself, or it is just a slower,
more expensive, less reliable BFS.

It earns the call in three cases, all of which the BFS structurally cannot
handle:

1. **The destination is not a room name.** "the temple", "a shop", "back
   where the guard was". BFS needs a row in `rooms`; a caller has prose.
2. **No route exists.** The useful answer is then not "no" but "the nearest
   unexplored exit pointing that way is west out of Market Square" — which
   means reading the map, not querying one path.
3. **Several rooms match.** Choosing needs judgement about which one the
   caller meant.

Where the destination *is* an exact known room name and a route exists, the
Navigator is strictly worse than calling `world_knowledge` directly. That is
stated in `consult_navigator`'s own description, so callers holding an exact
name are told to skip it, and the Judge — which has both tools — is told the
same. Being honest about this in the tool description is the mechanism;
hoping the model works it out is not.

## What got built

| Piece | File | What it does |
|---|---|---|
| `Tasks::Navigator` | `boukensha/lib/boukensha/tasks/navigator.rb` | `ALLOWED_TOOLS = %w[world_knowledge]`, `max_iterations: 4`, 350 output tokens. |
| `prompts/navigator/system.md` | — | Route → lead → nothing, in that order; never invent a direction. |
| `Orchestrator#register_navigator_tool` | `boukensha/lib/boukensha/orchestrator.rb` | Registers `consult_navigator` on a caller's registry, through `Registry#tool`. |
| `Orchestrator#navigate` / `#run_navigator` | same | The subagent turn: own Context, own Registry, one tool. |
| `Orchestrator#navigator_enabled?` | same | `tasks.navigator.enabled` **and** a knowledge store being present. |
| Transcript colour | `mud_monitor/public/style.css`, `app_test.rb` | Violet left border for navigator entries. |

## The decisions worth knowing about

### The denial is enforced, not assumed

`run_navigator` passes the **servers** to `subagent_context`, together with a
`Permissions` allowing only `world_knowledge`. So every MUD tool is filtered
out by Phase A's gate at registration and is genuinely absent — the
Navigator's registry contains exactly one tool.

Passing `servers: []` would have been simpler and would have produced the
same tool list today, but the guarantee would then rest on the argument
happening to be empty rather than on the allowlist. Routing it through the
same engine that enforces the Judge's surface means a test can assert
`tbamud__move` is unreachable, and the smoke run confirms dispatching it
raises `UnknownToolError` — it isn't merely unused, the Navigator cannot see
that moving is a thing it could do.

### Who gets `consult_navigator`

- **The Player** — the primary caller. It is the one that actually moves, and
  unlike `world_knowledge` (Phase H, withheld because the state block already
  tells the Player about its current room), *routing* is genuinely something
  the state block cannot answer: it shows one room and its exits, never a
  multi-step path.
- **The Judge** — so it can ask "is there even a way to the temple from
  here?" when assessing a plan's geography, without doing the map reading
  itself.
- **Not the Planner** — third phase running, same reason: Phase G made it
  toolless deliberately, and a tool turns it back into a slower Player.

### Enablement needs a store, not just a flag

`navigator_enabled?` is `tasks.navigator.enabled && knowledge_store`. With no
store the Navigator's only tool doesn't exist, so it would be a model call
guaranteed to answer "I don't know" — worth a config flag being quietly
ignored rather than a paid-for null result.

Note that enabling *only* the navigator is enough to get an `Orchestrator`:
`consult_navigator` is useful with no Planner and no Judge.

### One ordering change in `Boukensha.repl`

The Player's registry needs `consult_navigator` on it, and that tool belongs
to the Orchestrator — which needs the Logger. So the Logger is now built
*before* the run block and the Orchestrator immediately after it, ahead of
`perms.validate_referenced!`. Nothing about `Logger.new` depends on the
backend or builder, so moving it up is free, and doing it this way means a
user `allow:` block naming `consult_navigator` still validates correctly.

### Failure degrades

A raising Navigator returns `"navigator unavailable (…)"` rather than
propagating. The caller asked for directions, not for a reason to stop
playing. Same posture as `Mud::Hooks` and Phase H's knowledge tool.

## Isolation

The Navigator gets its own `Context`, so its lookups never enter the caller's
history. Because it is exposed as a *native tool*, the caller's context gains
exactly one `tool_call`/`tool_result` pair — the question and the answer —
and none of the intermediate map reads. There is a test pinning that a
`consult_navigator` dispatch leaves the caller's message count unchanged.

## Verified so far

Offline, against a real MCP server (`FakeMud`), a real on-disk store, and
real `Permissions` — model call stubbed:

```
navigator enabled:             true
player has consult_navigator:  true
player has NO world_knowledge: true      # Phase H's withholding still holds
player can still move:         true

navigator tools: ["world_knowledge"]
navigator CANNOT move:         true
navigator CANNOT look:         true
navigator ctx is separate:     true

navigator route lookup:
route from The Temple to Market Square (1 step): north→Market Square
navigator move refused:        true (UnknownToolError)

consult_navigator returns:     "north — 1 step."
caller context untouched:      true
logged navigator events:       ["navigator/start", "navigator/answer"]
```

## Not yet done

- **Live verification against a real model.** Third phase carrying this gap.
  The specific risk here is different from G and H: the Navigator's failure
  mode is *fabricating a direction the tool never gave it*, which costs the
  character real moves. The prompt forbids it in as many words, but only a
  live run shows whether that holds. Until then, treat a Navigator answer as
  unvalidated.
- **No cost ceiling on a caller's turn.** `consult_navigator` runs a whole
  agent loop inside another agent's turn; its tokens land on that turn's
  budget (`max_turn_tokens` is shared) but nothing warns when navigation is
  eating the play budget. The per-task cost rows in mud_monitor will show it
  after the fact.
- **No caching.** Two identical `consult_navigator` calls in one turn are two
  full subagent runs. The underlying map barely changes within a turn, so a
  memo keyed on `(from, to)` for the life of a turn would be nearly free.
- **`from:` is passed through to the prompt but not verified** — if a caller
  names a room that doesn't exist, the Navigator finds that out itself rather
  than being told up front.

## Try yourself

- **Ask it for somewhere unreachable** and check it returns a *lead* (an
  unexplored exit heading the right way) rather than either "no" or an
  invented route. That behaviour is the whole reason this isn't just the BFS.
- **Watch for the Player calling it when it already knows the room name** —
  that is the wasteful path the tool description tries to steer away from,
  and the transcript's violet entries make it obvious.
