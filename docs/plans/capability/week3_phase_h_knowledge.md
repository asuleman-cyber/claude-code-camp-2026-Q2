# Week 3 — Phase H: Knowledge as a Query API

**Status: built, tested, and verified live** — the Judge used it unprompted
against a real map. See [Verified live](#verified-live-2026-08-09).
Companion: [`capability_plan`](capability_plan). Previous:
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

### No second process

The tempting move is to expose this as its own MCP server — it would match
how every *other* tool reaches the agent, and it would make the query API
reusable from a non-Ruby client. Rejected: the store is already open in this
process, and the loader hands the orchestrator **the very same `Store`
instance** `Mud::Hooks` writes through.

A stdio hop would buy isolation nothing needs and cost a subprocess, a
handshake, and a second file handle on a SQLite database this process already
holds open. Sharing the instance also means a subagent reads exactly what was
just written, with no WAL visibility question to reason about. Worth
revisiting only if a non-Ruby client ever needs the same queries.

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

## Verified offline (before the live run)

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

## Verified live (2026-08-09)

Two sessions against the real CircleMUD, `claude-haiku-4-5`. The open
question was whether the Judge would use the tool at all or ignore it. It
used it, twice, unprompted, in the only judgement it performed:

```
[judge] world_knowledge {"kind":"overview"}
[judge] world_knowledge {"kind":"room", "name":"The Common Square"}
```

Two of the three modes exercised, and in a sensible order — orient first,
then ask about the specific room the plan was about. Nothing else in either
session called it: the Player doesn't have it (by design) and the Navigator
never ran (see Phase I).

The map it was querying was real, and had been built by the Player's own
movement during the same run:

```
rooms:        4      Poor Alley (x2)
walked edges: 5      The Eastern End Of Poor Alley (x3)
frontiers:    7      The Common Square (x1)
entities:     4      Wall Road (x1)
```

The revisit counts are worth noting: `x2` and `x3` mean Phase D's
known-room path fired repeatedly, resolving those rooms with **zero MUD
round trips**, while `frontiers: 7` is the unexplored-exit set the room
lookup renders as `(unexplored)`.

**`kind=route` was never exercised.** The Judge had no reason to ask for one
— the plans it assessed were about rooms the character was already standing
in or next to. So the BFS is unit-tested but has not answered a real model's
question yet, and neither has the ambiguity path.

## Not yet done

- **`kind=route` unexercised live** (above). It is the mode with the most
  logic behind it and the least live evidence.
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
