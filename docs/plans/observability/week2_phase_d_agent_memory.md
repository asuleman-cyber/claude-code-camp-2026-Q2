# Week 2 — Phase D: The Agent Gets Memory

**Status: done, in full.** Split out of the original combined report so each
phase has its own file. Previous: [C — room survey](week2_phase_c_room_survey.md).
Next: [E — player tracking](week2_phase_e_player_tracking.md). Companion:
[`week2_catchup_plan.md`](week2_catchup_plan.md).

The idea — give the agent memory instead of a room tool — was inspired by how
Andrew approached the same problem in his own run at this camp. The design
below is my own take on it, adapted to what I'd already built in Phases A–C
(my `inspect` composite, my permissions engine, my deterministic room
survey), not a port of his implementation.

**Test totals after Phases D–F:** `boukensha` 112 runs / 297 assertions,
`mud_manager` 34 runs / 203 assertions, `mud_monitor` 39 runs / 117 assertions —
all green (`rake test` in each directory). Every scenario below marked
"verified live" was run against the real CircleMUD on `localhost:4000`, not
just fixtures — where a real bug turned up, it's noted at the point it was
found and fixed.

> **Since this was written**, two of its "try yourself" items — the knowledge
> map and player tracking — were actually built, following
> [`player_map_plan.md`](player_map_plan.md). Both are flagged inline below
> where they're described as unbuilt. Totals are now `boukensha` 132/364,
> `mud_manager` 37/216, `mud_monitor` 62/219.

---

## Phase D — the agent gets memory (done, in full)

This is the headline feature of the whole catch-up effort: the player agent no longer
calls a tool to look around. Every model iteration, `Mud::Hooks#before_model` runs
automatically, figures out where the agent is, and injects a compact state block —
without a wasted MUD round trip on a room the agent has already seen.

### What got built

| Piece | File | What it does |
|---|---|---|
| Hooks framework | `boukensha/lib/boukensha/hooks.rb` | A 5-method null object (`before_turn`/`before_model`/`before_tools`/`after_tool`/`after_turn`) wired into `Agent` at 5 call sites around the turn loop. Every existing test kept passing unchanged — this is purely additive. |
| `RunDSL#hooks=` | `boukensha/lib/boukensha/run_dsl.rb` | The seam that lets the entrypoint install hooks *after* `registry`/`dispatch` exist (hooks need `dispatch`, which doesn't exist until the RunDSL block runs — the same chicken-and-egg problem I'd already solved for `inspect_room` in Phase C, solved the same way). |
| `Context#state_block` | `boukensha/lib/boukensha/context.rb` | One string, appended as a synthetic trailing user message by `Context#messages` — **never stored in `@messages`**, so it can't accumulate or go stale. Every backend and the logger get it for free with zero backend-specific code, because they all just call `context.messages`. |
| `Mud::RoomParser` | `boukensha/lib/boukensha/mud/room_parser.rb` | Was `Tools::RoomParser` (Phase C) — moved under a `Mud::` namespace since it's genuinely MUD-specific knowledge, not something a generic MCP host should know about. Gained `room_shape?` (a whitelist check deciding whether a move result is safe to substitute) and `exit_directions` (for fingerprinting). |
| `Mud::RoomSurvey` | `boukensha/lib/boukensha/mud/room_survey.rb` | Was `Tools::RoomSurvey` — same move, and its `#call` now returns structured data (`{room:, appraisals:, events_text:}`) instead of a formatted string, since nothing calls it as a tool anymore. |
| `Mud::Fingerprint` | `boukensha/lib/boukensha/mud/fingerprint.rb` | Weak (name+description+exit directions) and strong (+ destination names) SHA256 fingerprints — how "have I been here before?" gets answered without a server-assigned room id. |
| `Mud::Memory::Schema` / `Store` | `boukensha/lib/boukensha/mud/memory/{schema,store}.rb` | SQLite (WAL mode), versioned via `PRAGMA user_version` (no ActiveRecord, no migrations gem). Tables: `rooms`, `room_exits`, `entities`, `entity_sightings`, `player_state`. |
| `Mud::StateBlock` | `boukensha/lib/boukensha/mud/state_block.rb` | Renders the `[here] ...` block — description only on first visit, `✓`/`?` per exit for explored/frontier, live entity list with cached threat. |
| `Mud::Hooks` | `boukensha/lib/boukensha/mud/hooks.rb` | The actual memory logic — see below. |
| Knowledge tab | `mud_monitor/lib/mud_monitor/knowledge_store.rb` + `views/knowledge*.erb` | Read-only SQLite reader (opens/closes per request, no held-open handle — see the Windows note below), rooms list, room detail with exits, entities list, player state overview. |

### How the memory loop actually works

Three cases, cheapest first, all confirmed live:

1. **No move since the last resolution.** Reuse the already-known room. **Zero MUD
   calls, zero DB calls.**
2. **A move just happened.** `after_tool` already parsed the move's own output (it's a
   full room dump) and fingerprinted it in `Mud::Hooks#after_tool` — no extra MUD call
   needed. `before_model` looks that fingerprint up:
   - **Known room** (exactly one match) → touch visit count, link the edge from the
     previous room, done. **Zero MUD calls.**
   - **Unknown** (or, simplified — see below — ambiguous) → run a real survey
     (`poll` → `inspect` → `consider`/`examine` per distinct mob), persist it, link the
     edge.
3. **True cold start** (nothing resolved yet this process) → the same real survey.
   There's no shortcut; nothing has told the agent where it is yet.

`after_tool` also returns a one-line substitution (`"moved north → Market Square"`)
for the *model's* copy of a successful move result — the session log and mud_monitor
still see the MUD's full text, only the model's context gets the stub. A failed move
("Alas, you cannot go that way.") is never touched — `room_shape?` gates the
substitution to a strict whitelist (name + exits marker + vitals line all present), so
a failure the parser doesn't recognize passes through to the model verbatim rather than
risk swallowing a message the agent needs to see.

### Verified live (not just fixtures)

Walked from "A Dark Path" into "The Circle Of Stones" (a room with a real pit fiend)
and back:

```
=== cold start ===
[here] A Dark Path
exits: east→Too dark to tell. ? | west→The Circle Of Stones ?
here: There is a strange glow coming from the west. (object)

=== move west (new room) ===
model sees: "moved west → The Circle Of Stones"
[here] The Circle Of Stones
exits: east→Too dark to tell. ?
here: The pit fiend is sitting here. (mob — You ARE mad!)
calls: [poll, inspect]                      # no mobs in the first room, so no consider/examine

=== move east (KNOWN room) ===
model sees: "moved east → A Dark Path"
[here] A Dark Path  (visit 2)
exits: east→Too dark to tell. ? | west→The Circle Of Stones ✓   # frontier -> known edge
here: There is a strange glow coming from the west. (object)
calls: []                                    # zero MUD round trips
```

### Real bugs this caught (worth knowing about if you extend this)

1. **Windows file-handle bug in the JSONL appender pattern.** Holding a file handle
   open across writes (my original logger design from Phase B) blocks `Dir.mktmpdir`'s
   cleanup on Windows — a handle held open by one process can't be deleted by
   another. Fixed by open-append-close per write everywhere in this project now. **If
   you add another log/journal file, open-append-close, don't hold a handle.**
2. **SQL parameter-count-off-by-one** in `Store#update_player_state` — `ON CONFLICT
   ... DO UPDATE SET` doesn't need a bound parameter for `updated_at =
   excluded.updated_at`, but my code passed one anyway. Caught immediately by a smoke
   test before it ever hit a real test file — worth doing that (`ruby -e "require
   ...; smoke test"` before writing formal tests) whenever you're hand-writing raw SQL
   with positional `?` placeholders; it's very easy to miscount.
3. **A path-depth bug in `mud_monitor/app.rb`'s directory defaults**, caught by the
   `/knowledge` page coming back empty against real data rather than by any test
   failing (the unit tests all used explicit paths, which is why they didn't catch
   it). Worth remembering: directory-default bugs in Sinatra `set :x, File.expand_path(...,
   __dir__)` lines are exactly the kind of thing that only shows up against a real
   file layout, not a mock.

### Deliberate simplifications

- **Room identity is weak-fingerprint-only.** A fuller version would also
  disambiguate by arrival edge and, failing that, spend a `check(exits)` to compare
  strong fingerprints, inserting a genuinely unresolvable room as `confidence:
  provisional` and merging it later from future evidence. This build does none of
  that: exactly one match = known, anything else = treated as new. In a MUD this
  size that's likely fine (two rooms with byte-identical name+description+exit-
  directions are rare), but if you start seeing spurious duplicate rooms in the
  Knowledge tab, this is where to look. The schema already keeps the fingerprint
  column non-`UNIQUE`, which is the one thing that has to be right from day one to
  keep the door open for a fuller resolver without a migration that rewrites every
  foreign key.
- **A familiar mob in a known room isn't re-verified for free.** The bigger version
  of this idea — a cityguard met in a *new* room costing zero `consider`/`examine`
  round trips because its threat/health are already known — isn't implemented. What
  *is* implemented: a known room's entities are shown with cached threat from a
  previous survey (a free DB read), so the state block is still accurate; it's only
  the *new-room* case that still pays the full appraisal cost every time, identical
  description or not. The room-level saving — by far the larger one — is fully
  implemented.
- **Only `move` gets fingerprinted/substituted.** `flee` and `track` pass through
  unchanged. `flee` moves in a random direction, which makes it a worse fingerprint
  source anyway (you don't know what direction to link the edge from); this felt like
  the right one to cut first.
- **No `encounters` table** (combat outcome history — "lost to the minotaur at level
  3"). Nothing here depends on it; it's a natural follow-up, not a gap in what's built.

### Try yourself

- **Turn on Phase A's `allow:` permissions** on the live profile — it's built and
  tested but left off. Once you do, `inspect_room` doesn't need adding to any
  allowlist — it doesn't exist anymore; the player has no room tool at all now.
- ~~**Knowledge map.**~~ **Built since** — `/knowledge/map`, per
  [`player_map_plan.md`](player_map_plan.md) Part 2. The prediction that this was
  "genuinely just a rendering task on top of data that already exists" held: the only
  store-side addition was `KnowledgeStore#all_exits` (the whole graph in one query
  instead of N+1 per-room reads). It did need one thing the plan didn't anticipate —
  MUD geography isn't euclidean, so two rooms can want the same grid cell; the loser
  takes the nearest free cell and renders dashed rather than stacking invisibly behind
  the winner.
- **Ambiguous-fingerprint handling.** `Store#find_room_by_weak_fingerprint` already
  returns `:ambiguous` distinctly from `nil` — `Mud::Hooks#resolve_room!` currently
  treats them the same; that's the one line to change, plus building out the
  arrival-edge/strong-fingerprint disambiguation described above.
- **Play through a real session** with Phase D memory live and watch the Knowledge tab
  fill in — the single best way to find out whether the weak-fingerprint simplification
  actually causes problems in practice, before spending time on the fuller identity
  resolver. `/knowledge/map` (above) makes duplicate-room symptoms visible at a glance
  instead of buried in a table.

---

Next: [Phase E — track the player →](week2_phase_e_player_tracking.md)
