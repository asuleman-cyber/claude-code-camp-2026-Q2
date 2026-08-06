# Week 2 — Phases D, E, F: what I built, what I skipped, and what to try

Companion to [`week2_catchup_plan.md`](week2_catchup_plan.md). That file tracks the
checklist; this one is the narrative — what actually got built, the real bugs I found
and fixed along the way, every place I deliberately cut scope, and concrete
suggestions for what to pick up next.

The overall shape of the idea — give the agent memory instead of a room tool — was
inspired by how Andrew approached the same problem in his own run at this camp. The
design below is my own take on it, adapted to what I'd already built in Phases A–C
(my `inspect` composite, my permissions engine, my deterministic room survey), not a
port of his implementation.

**Test totals after this work:** `boukensha` 112 runs / 297 assertions,
`mud_manager` 34 runs / 203 assertions, `mud_monitor` 39 runs / 117 assertions — all
green (`rake test` in each directory). Every scenario below marked "verified live" was
run against the real CircleMUD on `localhost:4000`, not just fixtures — where a real
bug turned up, it's noted at the point it was found and fixed.

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
- **Knowledge map.** A visual room/exit graph laid out on a grid by real position
  (not a force-directed layout — "north is north" matters more than a generic graph
  library's ranking). `Store#all_rooms` + `#room_exits` already return everything a
  BFS-based grid layout would need; this is genuinely just a rendering task on top of
  data that already exists.
- **Ambiguous-fingerprint handling.** `Store#find_room_by_weak_fingerprint` already
  returns `:ambiguous` distinctly from `nil` — `Mud::Hooks#resolve_room!` currently
  treats them the same; that's the one line to change, plus building out the
  arrival-edge/strong-fingerprint disambiguation described above.

---

## Phase E — Track the player (change capture only; three items skipped)

### What got built: change capture

`Boukensha::Mud::Memory::Journal` (`boukensha/lib/boukensha/mud/memory/journal.rb`) —
an append-only JSONL log, daily-rotated like `sessions/`/`manager/`/`telnet/`. One
method matters: `#upsert(stream:, key:, value:, **meta)` compares against the last
value it saw for that `[stream, key]` **in this process** and writes a line only on an
actual change. Callers always hand it the current reading; the journal is the only
thing that decides "did this change."

Wired into `Store#update_player_state` (every player-state write) and `Store#insert_room`
(every new-room discovery, as a discrete `event`, since a room isn't a keyed value that
changes). Off by default (`MUD_JOURNAL_DIR`), now enabled on the live profile via
`.boukensha/.env`.

**Verified live:**

```json
{"stream":"player","key":"current_room_id","from":null,"to":1,"seq":1,...}
{"stream":"player","key":"last_direction","from":null,"to":null,"seq":2,...}
```

...and a second `before_model` call with no move in between produced **zero** new
lines — confirming the no-op suppression works against real hook traffic, not just
the unit tests.

Mud Monitor gained a **Progression** page (`/progression`,
`mud_monitor/lib/mud_monitor/journal_store.rb`) showing the raw change feed.

### What got skipped, and why

- **A deterministic test-player seeding script.** The idea is to delete and recreate
  the configured character on every run, then apply an admin "uplift" (level, gold,
  stats, skills, inventory, equipment) via commands like `set player gold <amount>`.
  None of that was live-verified against this specific server — and given the
  earlier lesson in this project (this MUD's actual `consider`/`examine` miss
  messages turned out to differ from what I'd assumed going in), guessing at
  *destructive* admin commands (character deletion!) without verifying them first
  against the shared dev character was too risky to do under time pressure. **If you
  build this:** live-verify every admin command against a throwaway character name
  first, the same way `bin/reset` was built in Phase A — confirm `set <player> gold
  <n>` (or whatever the actual syntax turns out to be) works as expected before
  wiring it into a script that runs unattended.
- **Multi-profile support.** Deliberately out of scope from the start — it touches
  `Config`'s directory resolution, the CLI, and Mud Monitor's profile selector, which
  is a bigger, more invasive change than the remaining time budget allowed for doing
  carefully.
- **A fuller player schema (score/skills/inventory/equipment).** Worth being honest
  here: a stock CircleMUD "should" print certain things a certain way, and this
  specific build almost certainly doesn't match that exactly (skill proficiency
  might be a word, not a percentage; an empty pack might read differently than
  expected). None of that was verified against this server. `player_state`'s
  existing hp/mana/move/level/gold/exp/position columns (built in Phase D) are live
  and journaled; the richer score-sheet/inventory/equipment tables are not. **If you
  build this:** capture real `score`/`inventory`/`equipment`/`practice` output from
  this server first (the same way Phase C's room fixtures were captured from real
  play) — don't assume the wording matches anything you've seen before.

### Try yourself

- Add a `player_inventory` table (the simplest additive slice of this) once you've
  captured what `inventory`/`score` actually print here.
- `Journal` is generic — nothing stops you from calling `.upsert`/`.event` from
  anywhere else that writes to `Store`, not just the two call sites wired in now (e.g.
  `entity` threat/health changes, once you decide that's worth a time series too).

---

## Phase F — Deeper observability (error log only; two items skipped)

### What got built: agent error log

`Boukensha::ErrorLog` (`boukensha/lib/boukensha/error_log.rb`) — one JSONL line per
caught exception: class, message, first 20 backtrace frames, a free-form `context`
string. Off by default (`BOUKENSHA_ERROR_LOG`), now enabled on the live profile.

Two places actually use it:

1. **`Mud::Hooks`' internal rescues.** Every `rescue StandardError` in `before_tools`/
   `after_tool`/`before_model`/`scrape_vitals` used to just swallow the exception —
   correct behavior (a broken hook must degrade the agent to "no memory," never crash
   the turn), but with nowhere to see *that* it happened. Now it logs, still degrades
   the same way.
2. **A new top-level safety net in `Repl#run_turn`.** Before this, only `LoopError`
   and `ApiError` were caught there — anything else (a genuinely unexpected exception)
   propagated and **crashed the whole REPL process**, losing the conversation. Added a
   broad `rescue StandardError` after the specific ones, logging with a backtrace and
   printing a message that the session is still alive.

**Verified live** with a real triggered failure (a broken `call_tool` lambda inside
`Mud::Hooks#before_model`): the hook degraded silently as designed
(`context.state_block` stayed `nil`, no exception reached the caller) and the error
log captured the full exception with a real backtrace pointing at
`RoomSurvey#call` → `Mud::Hooks#survey_and_persist!` → `#resolve_room!` →
`#before_model`.

Mud Monitor gained an **Errors** page (`/errors`,
`mud_monitor/lib/mud_monitor/error_log_store.rb`), newest-first.

### What got skipped, and why

- **Work attribution** (operation IDs/parent IDs/nesting so hidden automatic work —
  room surveys, hook DB writes — is visually distinguishable in mud_monitor from
  model-selected tool calls). Real scope here is large — a full span/trace layer on
  top of everything Phase D already does. Out of remaining budget.
- **OpenTelemetry export.** I decided to skip this on the strength of a lesson I'd
  already taken to heart from earlier in this project: it's cheap to bolt on, but it
  doesn't actually answer "what is my loop doing" — it's useful for performance, not
  behavior, which isn't the problem I'm trying to solve right now.

### Try yourself

- If you ever *do* want work attribution, the error log's `context:` string convention
  (`"Mud::Hooks#before_model"`, `"Repl#run_turn"`) is a small step short of it — you
  already know *where* things run, just not nested timing.
- Consider rotating/pruning `error.log` if it ever gets used in anger — right now it's
  one flat file with no size cap, which is fine for a dev tool but not forever.

---

## Summary: what to actually do next

In priority order, if you want to keep pushing on this:

1. **Turn on Phase A's `allow:` permissions** on the live profile — it's built, tested,
   and just needs an `allow:` block in `.boukensha/settings.yaml`.
2. **Play through a real session** with Phase D memory live and watch the Knowledge
   tab fill in — this is the single best way to find out whether the weak-fingerprint
   simplification actually causes problems in practice, before spending time on the
   fuller identity resolver.
3. **Knowledge map** (visual room graph) — genuinely just a rendering task on data
   that already exists (`Store#all_rooms`/`#room_exits`), no new agent-side work.
4. If you want Phase E's player tracking, **capture real `score`/`inventory`
   output first**, the same way every other piece of this project's parsing was built
   from real captures rather than assumption — that's the pattern that's worked every
   time it's been followed in this codebase, and the one place it would have been
   skipped (guessing at destructive admin commands) is exactly the piece that got cut.
