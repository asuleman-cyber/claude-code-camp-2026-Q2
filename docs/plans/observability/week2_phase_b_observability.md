# Week 2 — Phase B: Get Visibility Before Optimizing Further

**Status: done.** Split out of the original combined report so each phase has
its own file. Previous: [A — navigation](week2_phase_a_navigation.md). Next:
[C — room survey](week2_phase_c_room_survey.md). Companion:
[`week2_catchup_plan.md`](week2_catchup_plan.md).

---

## Phase B — get visibility before optimizing further (done)

**Goal going in:** you can't fix what you can't see, and this was the single
highest-leverage phase — most later work depended on it.

### The stack decision

The original plan for a unified observability app called for Rails plus a React
frontend. Neither Rails nor the `sqlite3` gem were installed on this machine, and
both were unverified on Windows — standing up that whole toolchain from scratch for
what is fundamentally a log viewer felt like a disproportionate lift. I already had a
Sinatra+ERB app from week 1 that did half of this job (agent session logs); I
extended that instead, with plain page-refresh polling for "live" views rather than
a server-push protocol. Less impressive on paper, but it shipped the same day and
needed zero new dependencies.

### What got built

| Piece | File | What it does |
|---|---|---|
| `ManagerLog` | `mud_manager/lib/mud_manager/manager_log.rb` | One JSONL record per tool call the daemon executes — mode, tool, args, result, elapsed time, errors — wired into the dispatcher. |
| `TelnetLog` | `mud_manager/lib/mud_manager/telnet_log.rb` | Every raw byte crossing the socket, both directions, wired into the session's reader thread and its send path. The login password is redacted at the source, never logged. |
| Millisecond timestamps | `boukensha/lib/boukensha/logger.rb` | The session logger's timestamps gained millisecond resolution plus a monotonic clock reading, so "duration between commands" became meaningful instead of ±1-second-quantized. |
| Mud Monitor | `mud_monitor/` (new Sinatra app) | Session transcript (forked from the week 1 log viewer — cost/token breakdown came along for free), plus new manager-log and telnet-log pages, a per-entry timing gutter, and live badges with auto-refresh on anything actively being written. |

### Verified live

Drove a real `look` call against the live game through the actual daemon (not a fake),
confirmed a manager-log record and telnet-log chunks were written, and confirmed the
running Mud Monitor app rendered them correctly — including confirming the login
password never appears anywhere on the rendered telnet page.

### Real bugs this caught

- **A Windows file-handle bug.** My first version of the JSONL log writer held a file
  handle open across writes for efficiency. On Windows, a handle held open by one
  process blocks another process (or even the same process's own cleanup code) from
  deleting that file — which broke test cleanup in a way that had nothing to do with
  the logging logic itself. Fixed by switching to open-append-close on every single
  write. At the volumes this project runs at, the extra open/close is free, and it's
  a pattern I kept using for every log/journal file built afterward.
- **A path-depth bug** in the new app's directory defaults, caught not by a test but
  by the sessions page coming back empty against my own real session logs after I
  pointed the app at them. All the automated tests used explicit paths, which is
  exactly why none of them caught it — a good reminder that directory-default logic
  needs at least one check against a real file layout, not just mocks.

### Deliberate simplifications

- No live server-push (SSE) — pages that are "live" just auto-refresh on a timer.
- No cross-layer diffing between what the telnet log saw and what the manager log
  saw (i.e., "what did the agent's own drain-before-send logic silently throw away
  between commands") — a genuinely interesting question, just not one I answered here.

### Try yourself

- The three logs (sessions, manager, telnet) all use the same seq/timestamp shape —
  a diff view between the manager and telnet logs for one time window would show
  exactly what got discarded between commands, which is one of the more interesting
  unanswered questions from this phase.

---

Next: [Phase C — fix the actual navigation problem →](week2_phase_c_room_survey.md)
