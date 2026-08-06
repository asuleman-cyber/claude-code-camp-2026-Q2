# Player Tracking + Visual Map — a build plan

**Status: built**, covered by tests, and verified against the live MUD. The
plan text is kept as written rather than rewritten in past tense — what it
predicted and what actually happened are both more useful than a tidied-up
version of either. See **[What building it actually taught](#what-building-it-actually-taught)**
at the bottom: three real bugs, every one of them found by the live pass and
missed by a green suite.

It's a plan, in the same family as
[`week2_catchup_plan.md`](week2_catchup_plan.md) and the two phase
report docs — checklists, one section per buildable chunk, and a "try
yourself" note wherever a scope decision was made rather than an oversight.

## Why this, why now

`knowledge.sqlite3` (Phase D) tracks rooms and entities well but knows
almost nothing about the *player* — `player_state` has hp/mana/move/level/
gold/exp/position and nothing else. No inventory, no equipment, no
score-sheet extras. And there's no visual map: `/knowledge` shows rooms and
exits as tables, which has all the *data* a map needs but none of the
picture.

## Does this persist? Yes — already solved, not new work here

`knowledge.sqlite3` is one file, opened at the same path
(`.boukensha/knowledge.sqlite3`) every time `boukensha` starts.
`Store#migrate!` only ever *adds* schema (via `PRAGMA user_version`), it
never wipes data. So everything below inherits accumulation across
sessions for free:

- Rooms/exits/entities already persist across every session (proven in
  Phase D — quit and restart the agent, the map of what it knows is still
  there).
- The player-tracking tables this plan adds work the same way: one row
  (or a small set of rows) per player, upserted every time, never reset.
- The map (Part 2) reads the live file on every page request, so it
  evolves *within* a session (as the agent explores, via auto-refresh) and
  *across* sessions (reopen Mud Monitor next week, everywhere the agent's
  ever been is already there) — with no sync step, because there's nothing
  to sync.

One related, out-of-scope gap worth knowing about while we're in this
territory: `Mud::Hooks`' in-memory mob-keyword cache does *not* carry over
between sessions — a fresh process starts it empty, even though the
underlying `entities.keyword` column is persisted. So a mob type already
known from last week still costs one `consider` round trip to re-verify its
keyword the first time it's seen again this session. Doesn't affect
anything in this plan (rooms/exits/player-state don't have this problem);
a one-line fix (seed the cache from `Store#all_entities` at
`boukensha_loader.rb` startup) if it's ever worth doing.

---

## Part 1 — Player tracking

**Scope:** score-sheet extras (age, armor class, alignment, exp-to-next-
level, quest points) + inventory + equipment. **Not** in scope: skills/
spells, level-up/death events as journal entries, multi-profile tracking.

### Step 1 — Capture real output first (do this before anything else)

- [x] Connect as the player (same pattern as every earlier fixture capture
  in this project) and run `score`, `inventory`, `equipment`. Save the raw
  text under `boukensha/test/fixtures/player/`.
  Done — `score.txt`/`inventory.txt`/`equipment.txt` captured (a level-1
  "Dummy the Swordpupil" with an empty inventory and a full worn-equipment
  set). One thing the capture caught that this doc's schema section didn't
  anticipate: two finger slots, two neck slots, and two wrist slots all
  print the *same* bracketed slot label twice — see Step 2's note.

This is deliberately first, not last. Every parser built in this project so
far that skipped this step got at least one detail wrong — this MUD's
`consider`/`examine` miss messages didn't match what the docs assumed, and
elsewhere the docs flagged skill proficiency printing as a word instead of
a percentage on this specific build. Assume nothing about `score`/
`inventory`/`equipment` wording until this step has actually run.

### Step 2 — Schema V2

- [x] `boukensha/lib/boukensha/mud/memory/schema.rb` — add `Schema::STEPS[2]`:
  - `ALTER TABLE player_state ADD COLUMN age INTEGER`, plus
    `armor_class`, `alignment`, `exp_to_next_level`, `quest_points`
    (all additive, all nullable — the migration mechanism already handles
    "apply every numbered step above the current version," no new
    machinery needed). Also added `max_mana`/`max_move` — v1 had `max_hp`
    but not those two (scrape_vitals never had a source for them); `score`
    does, so the same asymmetry didn't need to ship again.
  - `CREATE TABLE player_inventory (id INTEGER PRIMARY KEY, descr TEXT,
    keyword TEXT, quantity INTEGER, first_seen_at TEXT, last_seen_at TEXT)`
  - `CREATE TABLE player_equipment (id INTEGER PRIMARY KEY, slot TEXT
    UNIQUE, descr TEXT, keyword TEXT, first_seen_at TEXT, last_seen_at TEXT)`
    — `slot` is `UNIQUE` because equipment is naturally one-item-per-slot,
    unlike inventory. **Turned out not quite true**: the real capture shows
    two finger/neck/wrist slots sharing one label each. Schema kept as
    planned; `PlayerParser#parse_equipment` disambiguates the second
    occurrence as `"<label> (2)"` so the UNIQUE constraint still holds and
    both items are kept.

### Step 3 — `Mud::PlayerParser`

- [x] New file, `boukensha/lib/boukensha/mud/player_parser.rb`, pure text →
  Hash, no I/O — same shape as `Mud::RoomParser`. Three entry points:
  `parse_score(text)`, `parse_inventory(text)`, `parse_equipment(text)`.
  Built and tested against the step-1 fixtures, not the wording assumed in
  this plan. `test/test_player_parser.rb` asserts every `score`/`equipment`
  field against the real capture. One gap disclosed in the parser's own doc
  comment: the captured inventory was empty, so `parse_inventory`'s
  multi-item/quantity-suffix path is best-effort, not live-verified.

### Step 4 — `Store` methods

- [x] `update_player_score(fields)` — same upsert-on-`player_state` shape as
  the existing `update_player_state`, just the new columns. Implemented as
  a thin delegate to `update_player_state` (already fully generic over
  column names) — the wrapper exists so the score-refresh call site in
  `Mud::Hooks` reads as what it is.
- [x] `replace_inventory!(items)` / `replace_equipment!(items)` — diff the
  new list against what's currently stored, upsert what's still there,
  delete what's gone. Since `Store` already accepts an optional `journal:`
  (Phase E), emit `add`/`remove` (inventory) and `equip`/`unequip`
  (equipment) events through the existing `Journal#event` seam — no new
  logging mechanism, Phase E's journal already does exactly this job.

### Step 5 — Wire into `Mud::Hooks`

- [x] A `score` refresh once per **new-room survey** — that's already the
  moment the loop spends extra round trips (Phase D), so this doesn't add
  cost to the common "known room, zero calls" path. Wired at the end of
  `survey_and_persist!`. As a side effect, `player_state.level`/`gold`/
  `exp`/`position` — columns that existed since Phase D but were never
  actually written (see `week2_catchup_plan.md` Phase E's "player update —
  skipped" note) — are now populated too, since `score` is their only
  source anyway.
- [x] An inventory/equipment refresh triggered from `after_tool`, only when
  the just-dispatched tool was `get_item`/`drop_item`/`equip_item` — mirrors
  how vitals-scraping already piggybacks on existing traffic instead of
  polling every turn. There's no dedicated MCP tool for `score`/
  `inventory`/`equipment` (checked `mud_manager`'s `ToolSpec` — only
  typed gameplay primitives plus a `send_raw` escape hatch exist); all
  three refreshes go through `send_raw` rather than adding new tools to
  `mud_manager`, keeping this entirely a `boukensha`-side change.

### Step 6 — Mud Monitor: a Player page

- [x] `KnowledgeStore#player_inventory` / `#player_equipment` (mirrors the
  existing `#rooms`/`#entities` methods). Both rescue `SQLite3::SQLException`
  to `[]` for a pre-v2 `knowledge.sqlite3` that predates these tables.
- [x] New `/knowledge/player` route + `views/knowledge_player.erb` — vitals
  + score extras + inventory + equipment together, one page. Linked from
  `/knowledge`, not added to the top nav (same pattern as the existing
  `/knowledge/rooms/:id` sub-page).

**Deliverable:** a character sheet that's always current, built entirely
from readings the agent already takes or is cheap to trigger — no new
polling loop.

---

## Part 2 — Visual map

**Scope:** static grid, positioned by real compass direction, current-room
highlight, click-through to room detail, auto-refresh. **Not** in scope:
legend/color-coding, pan/zoom.

### Step 7 — `MudMonitor::MapLayout`

- [x] New, pure module (`mud_monitor/lib/mud_monitor/map_layout.rb`): rooms
  + exits in, positioned rooms + edges out. No I/O, no DB — a function of
  data, testable with a handful of synthetic fixtures.
- [x] BFS from the earliest-recorded room (the natural start-of-exploration
  anchor — the room with the oldest `first_seen_at`). North/south move the
  row, east/west move the column — "north is north," not a force-directed
  guess. Up/down don't get a third grid axis; render them as a small badge
  on the room box instead.
- [x] Rooms unreachable from the anchor by BFS (a teleporter, a one-way
  exit, a genuinely separate area) go in a clearly separate "disconnected"
  section — never silently dropped, never mis-placed into the main grid.

### Step 8 — `KnowledgeStore#all_exits`

- [x] One query returning every `room_exits` row across all rooms. Today's
  `#room_exits(room_id)` is per-room; the map needs the whole graph in one
  shot rather than N+1 queries.

### Step 9 — `/knowledge/map`

- [x] New route + `views/knowledge_map.erb`. CSS-grid rendering, one box
  per room positioned by `MapLayout`'s output. Because the grid is fixed,
  adjacent known exits are just a connecting border between neighboring
  cells — no line-drawing math needed for the common case. Rendered via a
  small `App#connection_sides` helper that turns each `MapLayout` edge into
  a highlighted border class on both of its endpoints.
- [x] The current room (`player_state.current_room_id`) gets a visible
  outline.
- [x] Clicking a room box goes to its existing `/knowledge/rooms/:id` page
  — no new detail view needed, the map is purely a navigation layer on top
  of what already exists.
- [x] Auto-refresh via the existing `live_refresh_tag` helper — same
  meta-refresh pattern as the manager/telnet/session live pages, not a new
  mechanism.
- [x] Linked from `/knowledge`.

**Deliverable:** open `/knowledge/map`, see the explored world as a picture
instead of a table, watch it grow while the agent plays.

---

## Testing

- [x] `MapLayout` — pure unit tests, no DB, no live MUD: north/south/east/
  west offsets land where expected; a disconnected room doesn't corrupt the
  main grid's coordinates. `test/mud_monitor/map_layout_test.rb`, 9 tests
  (offsets, up/down-as-badge, one-way/vertical-only disconnection, a cycle
  producing every edge not just the BFS spanning tree, an exit to an
  unsurveyed room id ignored rather than raising).
- [x] `PlayerParser` — built from the step-1 live captures, same pattern as
  `test_room_parser.rb` (real fixtures, not hand-written ones).
- [x] `Store`/`KnowledgeStore` new methods — in-memory SQLite, mirroring
  `test_memory_store.rb` / `knowledge_store_test.rb`. Includes journal
  coverage (inventory add/remove, an equipment swap journaling `unequip`
  then `equip`) and a pre-v2-DB compatibility test for the two new
  `KnowledgeStore` reads. Full suites green: 132 boukensha tests / 364
  assertions, 37 mud_manager / 216, 62 mud_monitor / 219.
- [x] Live-verification pass. Done in a follow-up session, and it earned its
  place — it's what found all three bugs in the section below, none of which
  the green suites had caught. What was actually run against the live MUD on
  `localhost:4000`:
  - A real cold-start `Mud::Hooks#before_model` through the real
    `Mcp::Dispatcher` (no fakes): `["poll", "inspect", "send_raw",
    "send_raw", "send_raw"]`, recording all **18** worn items and a full
    score sheet (`age=18 ac=39/10 align=12 max_mana=100`).
  - `/knowledge/map` against the real 22-room `knowledge.sqlite3`: 20 rooms
    positioned, 2 disconnected, zero cell collisions.
  - `/knowledge/player` rendering live score data.
  - Still not driven end to end: a full LLM-in-the-loop session watching the
    map grow move by move. The data path underneath it is verified; the
    pleasure of watching it fill in is yours.

---

## What building it actually taught

Three bugs, all found by the live-verification pass, none caught by a green
test suite. Worth reading together, because they share a shape: each one
produced a *plausible* result rather than an error.

### 1. `"> "` is not a prompt

The symptom: equipment came back empty from the live MUD even though the
character was visibly wearing eighteen things. Score worked fine.

`Session#read_until_prompt` waited for the literal string `"> "` — CircleMUD
ends every prompt with it, so it looked like a safe sentinel. But `equipment`
opens every line with a slot label, and `<used as light>` contains `"> "`
forty characters into the **first line** of output. The read stopped there
and returned:

```
"You are using:\r\n<used as light> "
```

which parsed cleanly as zero items. No exception, no warning — a short,
valid-looking string. Any command whose output contains an angle bracket
followed by a space had the same problem; `equipment` is just the one that
does it every single time.

The sentinel is now the vitals shape (`/\d+H\s+\d+M\s+\d+V[^\r\n]*>\s/`),
which is the same assumption the agent side already makes when it scrapes
`22H 100M 83V` off a result. Not a new dependency on the server's format —
an existing one, applied where it was missing.

### 2. A fake that lies is worse than no fake

Fixing #1 made the `mud_manager` suite take **99 seconds** instead of 9,
while still passing. `FakeMud`'s prompt was `<100hp 100m 100v> ` — close
enough to look right, different enough that the new sentinel never matched
it. Every dispatcher call in the suite fell through to the
timeout-and-drain fallback: green, slow, and exercising the error path
instead of the real one.

That divergence is also *why* bug #1 survived so long — the fake could never
have reproduced it. `FakeMud` now writes the real server's exact prompt
shape, and the suite is back to 12s. If you touch the wire format on either
side, change both.

### 3. Change-on-write has no cold start

Inventory and equipment refreshed only after a `get_item`/`drop_item`/
`equip_item` call — correct for keeping them current, useless for a
character who logs in already wearing a full kit and whose agent never picks
anything up. The tables stayed empty for the whole run.

The first survey of a process now syncs both once (`@items_synced`), which
is the read that gives the change-triggered refreshes something true to
diff against. Two extra round trips per process, not per room.

### And one design gap the plan didn't anticipate

MUD geography is not euclidean: north, east, south, west can leave you
somewhere that is not where you started. `MapLayout` assigned grid cells
straight from compass offsets with no check that the cell was free, so two
genuinely different rooms could collide — and a CSS grid renders both in one
cell, the second invisible behind the first while the legend still counts
it. The current 22-room map has no collisions, so this was latent rather
than live, found by constructing a five-room loop rather than by looking at
real data.

A room whose true cell is taken now spirals out to the nearest free one and
renders dashed, flagged `displaced`. Its position is then a lie about
geometry but an honest one about existence — the right trade for a debugging
view, as long as the flag says which rooms to distrust.

---

## Try yourself (explicitly cut from this plan, not forgotten)

- **Skills/spells tracking.** Same shape as inventory/equipment, just not
  built here — add a `player_skills` table and a `parse_skills` entry to
  `PlayerParser` once you've captured real `practice` output.
- **Level-up / death as journal events.** The plumbing already exists
  (`Journal#event`) — just needs text-pattern detection and a call site in
  `Mud::Hooks`.
- **Map legend / color-coding.** Rooms with unresolved mobs shaded
  differently, visit-count as color intensity, etc. — a rendering-only
  addition once the base grid exists.
- **Pan/zoom.** Only worth it once the explored area is big enough that a
  fixed canvas gets cramped.
- **Cross-session keyword-cache seeding.** Noted above — a one-line fix,
  unrelated to the map, adjacent enough to mention here.
