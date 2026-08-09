# Week 2 — Phase C: Fix the Actual Navigation Problem

**Status: done.** Split out of the original combined report so each phase has
its own file. Previous: [B — observability](week2_phase_b_observability.md).
Next: [D — agent memory](week2_phase_d_agent_memory.md). Companion:
[`week2_catchup_plan.md`](week2_catchup_plan.md).

---

## Phase C — fix the actual navigation problem (done)

**Goal going in:** replace slow, unreliable room inspection with something fast and
deterministic.

The obvious path here was an LLM-driven subagent that decides which MUD commands to
call and parses the result — I skipped building that entirely and went straight to a
deterministic version, on the theory that a fixed command sequence plus a pure-text
parser could do the same job with zero model calls. That turned out to be right.

### What got built

| Piece | File | What it does |
|---|---|---|
| `RoomParser` | `boukensha/lib/boukensha/tools/room_parser.rb` (later moved under `Mud::` in the next phase) | Pure text → Hash, no I/O. Splits the `inspect` composite's output into name, description, vitals, exit map, and mob/object lines — classified by their ANSI color, verified against real captures rather than assumed. |
| `RoomSurvey` | `boukensha/lib/boukensha/tools/room_survey.rb` (moved under `Mud::` in the next phase, same as `RoomParser`) | `poll` → `inspect` → classify → `consider`/`examine` per **distinct** mob (deduplicated, so three identical mobs cost one round-trip pair, not three) → a compact summary. Zero LLM calls anywhere in the sequence. |
| `inspect_room` native tool | wired at the agent entrypoint | Drives `RoomSurvey` through the same permission-gated dispatch path every other tool uses (Phase A's engine), so it's subject to the same `allow:` rules rather than being a special ungated case. **Deleted in Phase D** — once hooks establish position automatically every iteration, the agent doesn't need a room tool at all. It doesn't exist in the current code. |

### Real fixtures, not hand-written ones

I captured actual room text from the live game — including a genuine mob encounter
(a pit fiend, sitting in a stone circle) — and built the parser tests from those
captures rather than writing synthetic fixtures by hand. That paid off immediately:
the miss-message pattern I'd assumed the game would use when a `consider`/`examine`
target doesn't resolve turned out to be wrong for this specific server (`consider`
answers with *"Consider killing who?"*, `examine` answers with *"You do not see that
here."* — two different messages, neither of them what I'd guessed going in). Building
the miss-detection from what the server actually says, rather than porting an
assumption, is the whole reason this parses correctly.

### Verified live

Walked into the pit fiend's room through the actual wired-up native tool (not the
test fixtures) and got back:

```
mobs: The pit fiend is sitting here. (You ARE mad!; The pit fiend is in excellent condition.)
```

with zero LLM calls anywhere in the path.

### Deliberate simplifications

- **No ranked-candidate retry on a keyword miss.** The parser's keyword guesser
  returns one best guess; if `consider` says that keyword doesn't resolve, the mob is
  cached as permanently unresolved rather than retried with a second guess. Worth
  revisiting if misses turn out to be common in real play.
- **The look-candidates problem — detecting hidden, examinable nouns in room prose
  (a fountain, a statue, wall paintings) that the game never lists explicitly — was
  skipped entirely.** This is the one genuinely fuzzy piece of the whole survey; every
  other field is a mechanical parse, and this one isn't. Not attempted here.

### Try yourself

- If you want look-candidates, the room descriptions are already being parsed and
  stored — the missing piece is purely the noun-extraction/filtering layer on top,
  not any new plumbing.
- The keyword-miss cache is a plain in-memory Hash today; if you add the retry logic
  above, that's also the natural place to make the cache smarter (e.g. tracking *which*
  guesses were tried, not just pass/fail).

---

Next: [Phase D — the agent gets memory →](week2_phase_d_agent_memory.md)
