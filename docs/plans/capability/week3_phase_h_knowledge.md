# Week 3 — Phase H: Knowledge as a Query API

**Status: built and tested; not yet verified live against a real model.**
Companion: [`capability_plan`](../capability_plan). Previous:
[G — orchestrator](week3_phase_g_orchestrator.md).

Phase D gave the agent a room graph in `knowledge.sqlite3`. It only ever came
back out one way: `Mud::Hooks` rendering the **current** room as a state
block, every iteration, whether or not anything wanted it. Nothing could ask
about a room it wasn't standing in, and nothing could ask whether two rooms
connect. Phase H adds the ask side of the same data.

**Test totals after Phase H:** `boukensha` 210 runs / 606 assertions,
`mud_manager` 41 / 217, `mud_monitor` 71 / 249 — all green. Up from
177 / 525 at the end of Phase G.

---

## What got built

| Piece | File | What it does |
|---|---|---|
| `Store#route_to` | `boukensha/lib/boukensha/mud/memory/store.rb` | BFS over `room_exits`, returning `[{direction:, room_id:, name:}]`, `[]` for from==to, `nil` for no known route. |
| `Store#all_exits` | same | The whole graph in one query instead of N+1 per-room reads. |
| `Store#find_rooms_by_name` | same | Exact match first, then substring, both case-insensitive. |
| `Mud::KnowledgeTool` | `boukensha/lib/boukensha/mud/knowledge_tool.rb` | The `world_knowledge` native tool: `kind=overview\|room\|route`. |
| `subagent_context(native_tools:)` | `boukensha/lib/boukensha.rb` | Registers non-MCP tools into a subagent's registry, through the same `Registry#tool` gate. |
| `RunDSL#knowledge_store=` | `boukensha/lib/boukensha/run_dsl.rb` | The seam the entrypoint uses to hand the live Store to the orchestrator — same pattern as `hooks=`. |
| `Orchestrator#native_tools` | `boukensha/lib/boukensha/orchestrator.rb` | `[]` when there is no store; otherwise the one registration callable. |

## The decisions worth knowing about

### No second process, unlike the reference

The reference design moved its equivalent out to a separate `log_viz --mcp`
server. Here the store is already open in this process — the loader hands the
orchestrator **the very same `Store` instance** `Mud::Hooks` writes through.
A stdio hop would buy isolation nothing needs and cost a subprocess, a
handshake, and a second file handle on a SQLite database this process already
holds open. Sharing the instance also means a subagent reads exactly what was
just written, with no WAL visibility question to reason about.

### An unwalked exit is not a route

`route_to` walks only edges where `target_room_id IS NOT NULL` — and that
column stays NULL until the agent has actually stood in the destination
(Phase D's frontier marker). So the question it answers is "can I get there
by a route I have already walked?", never "does the world contain a path?"

That distinction is the whole value of the tool for planning. A `room` lookup
still *shows* frontiers, explicitly marked `(unexplored)`, because "there is
an exit west that nobody has tried" is exactly what turns "where do I go
next?" into a decision instead of a guess. But a frontier can never appear
inside a route, and there is a test pinning that
(`test_an_unwalked_exit_is_never_part_of_a_route`).

BFS rather than Dijkstra because every MUD step costs one move — unweighted,
so breadth-first is already a genuine shortest path.

### The Player deliberately gets nothing

`native_tools` is a subagent-only path. The Player's room knowledge already
arrives free in the state block every iteration; giving it a tool to ask for
what it is being told anyway would be a round trip to learn nothing, and
would undo the zero-LLM-call revisit saving Phase D exists for. Phase H is
for the roles that *aren't* standing in the room.

The plan said "Judge/Navigator/**Planner**". The Planner does not get it
either, and that is a deliberate departure: Phase G made the Planner toolless
on purpose (one bare model call, no loop), and handing it a tool would turn
it back into a slower Player. It plans from the goal and the memory it is
given; finding out what the world looks like is the Player's job. Revisit if
plans turn out to be consistently unrealistic about geography — the Judge
saying `replan` with "no known route to X" is the intended path for that
today.

### Read-only in the strong sense

Every `Store` method the tool calls is a `SELECT`, and it never touches the
MUD. So an over-curious subagent wastes tokens and nothing else — asking
about the world cannot change it. The smoke run asserts the store is
unchanged after a full sweep of queries.

It is on `Tasks::Judge::READ_ONLY_TOOLS`, so it goes through the same Phase A
`Permissions` gate as everything else rather than getting a bypass for being
"only a read".

### Failure degrades, it doesn't raise

`KnowledgeTool.call` rescues everything into `"world knowledge unavailable
(…)"` — the same posture `Mud::Hooks` takes. A locked database makes a
subagent ignorant, not dead.

## A bug the tests caught

A named room lookup that found nothing returned **"current room: unknown
(nothing resolved yet this session)"** — because the not-found branch was
shared with the no-name-given branch. Two completely different answers ("your
room name was wrong" vs "I don't know where I am") wearing one message, which
would have had a model re-asking a question it had already answered
correctly. Split into two branches; `test_room_reports_an_unknown_name` pins
it.

## Verified so far

Offline, against a real MCP server (`FakeMud`), a real on-disk SQLite store,
and real `Permissions` — no model call involved:

```
orchestrator has native tool:   true
judge has world_knowledge:      true
judge still cannot move:        true
player has no world_knowledge:  true

--- overview ---
known world: 2 rooms, 0 distinct things seen, 1 unexplored exits
currently in: The Temple (room 1, visited 1x)

--- room Market Square ---
Market Square (room 2, visited 1x)
Busy.
exits: west→Too dark to tell. (unexplored)

--- route ---
route from The Temple to Market Square (1 step): north→Market Square

--- route to nowhere ---
no room called "Atlantis" has been visited.

store still read-only: true
```

## Not yet done

- **Live verification against a real model.** Same gap as Phase G: the
  plumbing is proven, the prompt wording is not. The specific thing to watch
  is whether the Judge uses `kind=route` to catch geographically impossible
  plans, or ignores the tool entirely.
- **Ambiguity resolution is "ask again".** More than one room matching a name
  returns a list and asks for the exact name, costing a round trip. Ranking
  by proximity to the current room would usually pick right first time.
- **No entity search.** You can ask what is in a room; you cannot ask "where
  have I seen a cityguard?", though `entity_sightings` holds exactly that.
  Cheap to add if the Navigator wants it.
- **`route_to` loads the whole edge table per call.** Fine at this map size
  (one `SELECT`, a few hundred rows); it would want an incremental frontier
  query long before it wanted anything cleverer.

## Try yourself

- **Ask for a route across a map with a gap in it** — the honest "the rooms
  in between have not been walked yet" is more useful to a planner than a
  route that assumes an untried exit leads somewhere.
- **Add `world_knowledge` to the Navigator's allowlist in Phase I** — it is
  the tool that phase is built on; the registration path is already there.
