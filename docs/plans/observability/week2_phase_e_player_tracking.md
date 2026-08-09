# Week 2 — Phase E: Track the Player

**Status: change capture built; three items skipped.** Split out of the
original combined report so each phase has its own file. Previous:
[D — agent memory](week2_phase_d_agent_memory.md). Next:
[F — error log](week2_phase_f_error_log.md). Companion:
[`week2_catchup_plan.md`](week2_catchup_plan.md). Test totals: see the note
at the top of [Phase D's report](week2_phase_d_agent_memory.md) — D, E, and F
were built and tested together.

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
- ~~**A fuller player schema (score/skills/inventory/equipment).**~~ **Built since**,
  except skills — see below. The blocker named here was real and was the right call:
  the fix was simply to *do* the capture step first. Doing it caught two things a
  from-memory implementation would have got wrong — equipment slots are **not**
  one-per-slot (two finger, two neck, two wrist slots all print the same bracketed
  label, so the schema's `UNIQUE` constraint needed a `" (2)"` suffix to survive), and
  `score` reports quest points on two different lines with two different spellings.
  Skills/spells are still unbuilt for exactly the original reason: no `practice`
  capture yet, and proficiency may print as a word rather than a percentage.

### Try yourself

- ~~Add a `player_inventory` table~~ — **built since** (plus `player_equipment` and the
  score-sheet columns). Capturing the real output first was, again, what made it work.
- `Journal` is generic — nothing stops you from calling `.upsert`/`.event` from
  anywhere else that writes to `Store`, not just the two call sites wired in now (e.g.
  `entity` threat/health changes, once you decide that's worth a time series too).
- **Skills/spells tracking** — the last unbuilt slice of player state. Same recipe as
  the rest: capture real `practice` output first, then write the parser against it.
  That order is the one thing in this project that has worked every single time it's
  been followed, and every time it was skipped, something was wrong.

---

Next: [Phase F — deeper observability →](week2_phase_f_error_log.md)
