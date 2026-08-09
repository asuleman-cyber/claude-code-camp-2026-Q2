# Week 3 — Phase J: Cross-Session Character Memory

**Status: built and tested; not yet verified live against a real model.**
Companion: [`capability_plan`](../capability_plan). Previous:
[I — Navigator](week3_phase_i_navigator.md). This is the last phase of
Week 3.

Everything the agent knew died with the process. `knowledge.sqlite3`
persisted where the *rooms* are, but not that a pit fiend killed this
character at level 3, or that it was halfway through finding the guild when
the session ended. Phase J gives one character a memory of its own
experience, carried from run to run.

**Test totals after Phase J:** `boukensha` 263 runs / 746 assertions,
`mud_manager` 41 / 217, `mud_monitor` 73 / 259 — all green. Up from
225 / 651 and 72 / 254 at the end of Phase I.

---

## What got built

| Piece | File | What it does |
|---|---|---|
| `PlayerMemory` | `boukensha/lib/boukensha/player_memory.rb` | `<name>.jsonl` append-only records + `<name>.md` bounded prose digest, under `<config>/memory/`. |
| `Tasks::Chronicler` | `boukensha/lib/boukensha/tasks/chronicler.rb` | Zero tools, 800 output tokens. |
| `prompts/chronicler/system.md` | — | Four fixed headings; merge-don't-append; forget deliberately. |
| `Orchestrator#flush_memory!` / `#note_activity!` | `boukensha/lib/boukensha/orchestrator.rb` | Redistils the digest at a boundary, skipping when nothing new happened. |
| `run_planner(player_memory:)` | same | The *only* path memory takes toward the Player. |
| `Config#memory_enabled?` / `#character_name` | `boukensha/lib/boukensha/config.rb` | `memory.enabled` (off by default) and the character to file memory under. |
| REPL flush points | `boukensha/lib/boukensha/repl.rb` | `/clear`, `/exit`, EOF, plus every non-`continue` verdict. |
| Transcript colour | `mud_monitor/public/style.css` | Slate left border for chronicler entries. |

## The decisions worth knowing about

### This is not knowledge.sqlite3, and the split is the point

The room store holds **spatial** truth — where rooms are, what stands in
them — and answers "what is there?". This holds **narrative** truth — what
was tried, what it cost, what to do differently — and answers "what have I
learned?". Trying to put the second kind into a room graph produces a schema
of loose ends nothing can query.

That distinction is also why `Tasks::Chronicler` has **zero tools**, which
is design rather than omission. A Chronicler with tools would go and check
the world before writing memory, which sounds diligent and is exactly wrong:
`world_knowledge` already answers "what is there?" live and accurately, and
copying it into a prose digest just makes a staler second copy of facts that
are already free. Denying tools is how the digest stays the thing no tool
can produce.

### Append-only history, rewritten digest

Two files, doing different jobs:

- `<name>.jsonl` — permanent, append-only. Nothing rewrites it.
- `<name>.md` — rewritten wholesale every flush.

The digest is what a Planner reads *every session*, so it has to stay small,
and it stays small because it is rewritten rather than appended to. A memory
that only grows is a memory that eventually costs more than it is worth —
so the Chronicler is told to merge, sharpen, and **forget deliberately**
(drop resolved threads, obvious discoveries, mistakes that can't recur).
`MAX_DIGEST_CHARS` truncates on a line boundary as a backstop, so a
Chronicler that ignores its budget can't quietly inflate every future
planning call.

### Memory reaches the Player only through the Planner

The Player's prompt and context are untouched by Phase J. Memory goes into
`run_planner`, becomes a plan, and the plan reaches the Player exactly the
way Phase G already delivered it.

Two reasons. It costs one call's tokens **at a decision point** instead of
riding along on every iteration of every turn forever — the Player's context
is the expensive one, since it's the one that loops. And it leaves the
already-tested Player path completely stable: Phase J adds no new way for
the thing that actually plays the game to behave differently.

There's a test asserting the digest never appears in the Player's context or
system prompt, only the plan derived from it.

### Every write is open-append-close

Not a stylistic preference — a documented bug in this project. Phase B's
logger held a handle open across writes, and on Windows a handle held by one
process blocks another from deleting the file, which broke `Dir.mktmpdir`
cleanup in tests (found in Phase D). `PlayerMemory` opens, appends, and
closes on every write, and there's a test that removes the tmpdir afterwards
— it fails on Windows if a handle regresses.

### Flush points, and why activity is tracked

Memory is redistilled at `/clear`, `/exit`, EOF, and **any Judge verdict
that isn't `continue`**. That last one matters: flushing only at exit means
a session killed mid-play leaves nothing behind, and a `replan`/`flag` is
precisely the moment something concluded or went wrong.

`/clear` chronicles **before** wiping — flushing afterwards would faithfully
record an empty session over a real one.

`note_activity!` guards against paying twice: a `:flag` verdict followed by
`/exit` moments later would otherwise run two Chronicler calls over the same
already-recorded play. A flush with no new activity is a no-op.

### The character name comes from `MUD_NAME`

Read from the `mud` MCP server's own `env` block — the same value the daemon
logs in with — so the memory file and the character on screen cannot drift
apart. An explicit `memory.character` overrides it. The name becomes a
filename, so it is **whitelisted** (`[A-Za-z0-9_-]`) rather than escaped:
`../../etc/passwd` becomes `etcpasswd`, and a name that sanitizes to nothing
yields no memory rather than a mystery file.

### Failure degrades, everywhere

`record`/`write_digest` return `false` rather than raising; `flush_memory!`
rescues into a logged error and `nil`. These are exit paths — losing a
session's memory is bad, but crashing the shutdown that was trying to save it
is worse.

## Verified so far

Two sequential sessions against a real on-disk config and `PlayerMemory`,
model calls stubbed:

```
=== SESSION 1 (no memory yet) ===
character:                   Gandalf
starts empty:                true
planner saw memory:          nil
memory NOT in player prompt: true
digest written:              true

files on disk: ["Gandalf.jsonl", "Gandalf.md"]

=== SESSION 2 (reads memory back) ===
starts empty:                false
planner saw memory:          true
  ...the mistake:            true      # "pit fiend" carried across
  ...the open thread:        true
player prompt has plan:      true
player prompt has NO memory: true
verdict:                     :replan
replan triggered a flush:    true
digest updated:              true
old digest replaced:         true      # rewritten, not appended

raw record kinds:  {"session"=>2, "digest_written"=>2}
flush reasons:     ["exit", "verdict:replan"]

tmpdir removed cleanly (no held handles): true
```

## Not yet done

- **Live verification against a real model.** Fourth phase carrying this, and
  here the risk is specific: the Chronicler is told to *forget* as part of
  its job, and a model that over-forgets silently loses the character's
  history with no error anywhere. The `.jsonl` is the audit trail that makes
  that recoverable, but nothing currently diffs one digest against the last
  to show what was dropped.
- **No `Session.play`.** Still the REPL only — the autonomous outer loop
  remains open from Phase G.
- **One character per config directory.** `MUD_NAME` is a single value in
  `settings.yaml`; running several characters means several config dirs.
  `PlayerMemory` itself is already keyed by name and would not need changing.
- **The Chronicler sees a transcript tail, not the whole session.**
  `render_transcript` (shared with the Judge) takes the last 12 messages, so
  a long session's early events are distilled only if an earlier flush caught
  them. Frequent flushes cover this in practice; a single very long turn
  would not be.
- **Nothing reads the `.jsonl` back but the Chronicler.** No mud_monitor page
  for memory — the digest is a file you open, and per-flush history is
  visible only in the session transcript.

## Try yourself

- **Play two sessions and read `<config>/memory/<name>.md` in between.** The
  question worth asking is whether the open threads are things you'd actually
  want the next session to pick up, or generic filler — that's the difference
  between memory and a diary.
- **Delete the digest but keep the jsonl**, then flush again: the Chronicler
  writes a first digest from scratch, which is the recovery path if a
  digest ever gets over-forgotten.
- **Turn memory on with the Planner off.** Nothing reads the digest then —
  memory is written and never used, which is a quick way to see that the
  Planner really is the only route to the Player.
