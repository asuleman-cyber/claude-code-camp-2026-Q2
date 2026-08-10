# Boukensha — an AI that learns to play a text adventure game

This is the repo built for the Claude Code Camp operated by
[ExamPro](https://www.exampro.co).

## What is this project?

A MUD ("Multi-User Dungeon") is an old-school, text-only online game: you
type commands like `look`, `north`, or `attack goblin`, and the game replies
in prose describing what happened. This project builds an AI agent —
**Boukensha** — that plays one of these games entirely on its own: reading
what the game says, deciding what to do, and typing its own commands back.
No human at the keyboard.

It's a multi-week coding camp project, and the agent was built up in
stages, one capability at a time — starting from "can it even hold a
conversation with the game" and ending with an agent that sets itself a
goal, checks whether it's actually making progress, and remembers what it
learned the next time it logs in. It's been run against a real, live game
server throughout, not just tested in theory.

> Two real sessions against a live game server cost **$0.10** total, and
> produced a genuine mid-session correction — the reviewer role paused the
> agent partway through, decided to rethink its plan, and what it had
> learned carried over into the next session. Full run recorded in
> [`docs/journal/3_capable.md`](docs/journal/3_capable.md).

## The journey, week by week

| Week | What was added |
|---|---|
| **Week 0 — Explore** | Learned to talk to the game at all: opening a raw text connection and sending/receiving commands. |
| **Week 1 — Baseline** | The first working agent: read the game's text, decide on an action, send it — one exchange at a time. |
| **Week 2 — Observability** | Gave the agent a memory of the game *world* (a map of rooms it has visited) and built a dashboard + tracing so a human can watch exactly what it saw and why it acted. |
| **Week 3 — Capable** *(current)* | Gave the agent four new abilities: to **plan** ahead, **check** its own progress, **find its way** around, and **remember** lessons across separate play sessions. |

## How the current agent thinks

At its core, one loop repeats every time the agent plays:

```mermaid
%%{init: {"flowchart": {"useMaxWidth": false}}}%%
flowchart LR
    A["🧭🤖 Plan<br/>write down a goal<br/>and a few steps"] --> B["🎮🤖 Play<br/>read the room,<br/>decide, act"]
    B --> C{"🔍🤖 Check<br/>is this working?"}
    C -->|"yes, keep going"| B
    C -->|"not really"| D
    B -.->|"session wraps up"| D["📝🤖 Remember<br/>write down what<br/>was learned"]
    D -.->|"back to planning,<br/>next time"| A
```

🤖 marks a step that's an AI model call — all four are, none of this loop is
scripted logic.

- **Plan** — before playing, the agent writes itself a short goal and a few
  concrete steps.
- **Play** — it reads the room, decides what to type, and sends it — over
  and over, like a person playing the game turn by turn.
- **Check** — periodically, a second "reviewer" role looks at what just
  happened and decides: keep going, or rethink the plan. It can also raise
  a flag for a human to see — play continues either way, the flag is just a
  note that something looked off.
- **Remember** — when a play session wraps up, or the plan changes, the
  agent writes itself a short note about what it learned, so it isn't
  starting from scratch next time.

Each of those four roles is a separate call to an AI model — not scripted
logic — and each is deliberately limited to only what its job needs: the
reviewer can't move the character, for instance. That's what makes each one
trustworthy rather than just another thing that could go wrong, and it's
also why this is an *orchestration* of several small, narrow AI calls
rather than one big one doing everything.

*(For readers who want the code-level names: these four roles are called
the Planner, Player, Judge, and Chronicler — see
[`week3_capable/README.md`](week3_capable/README.md) for the full technical
write-up.)*

## Architecture, for a closer look

The diagram above is the mental model; this is the same loop with the
actual components involved — for reviewers who want to see the shape of the
system without reading source yet:

```mermaid
%%{init: {"flowchart": {"useMaxWidth": false}}}%%
flowchart TD
    Input(["Human turn input"]) --> PlanGate{"Plan needed?"}
    PlanGate -->|"yes"| Planner[["🤖 Planner<br/>writes goal + steps<br/>(no tools)"]]
    PlanGate -->|"no"| Player
    Planner --> Player

    subgraph Turn["Player turn"]
        direction TB
        Player[["🤖 Player"]] -->|"game commands"| MUD[("mud-manager<br/>MCP server")]
        Player -->|"fuzzy destination"| Navigator[["🤖 Navigator<br/>(read-only)"]]
        MUD --> Player
        Navigator --> Player
    end

    Player --> Judge[["🤖 Judge<br/>checkpoint<br/>(read-only)"]]
    Judge -.->|"room / route lookups"| KB[("Knowledge store<br/>room map")]
    Judge -.->|"fuzzy destination"| Navigator
    Navigator -.->|"room / route lookups"| KB

    Judge -->|"continue"| Input
    Judge -->|"replan"| Input
    Judge -->|"flag (warns; play continues)"| Input
    Judge -->|"replan or flag"| Chronicler[["🤖 Chronicler<br/>(no tools)"]]

    Boundary(["/exit, /clear, EOF —<br/>independent of the Judge"]) --> Chronicler
    Chronicler --> Memory[("Player memory<br/>digest")]
    Memory -.->|"read back next session"| Planner
```

A few things worth knowing at a glance:

- **Every 🤖 box is a separate API call**, not scripted logic — Planner,
  Player, Judge, Navigator, and Chronicler are each configured
  independently (provider + model, see Setup) and can run on different
  models: a cheap one for a quick checkpoint, a stronger one for actual
  play. Nothing here is one model pretending to be five.
- **Judge and Navigator are permission-gated to read-only**, not just asked
  nicely — the tools that would move the character are never even
  registered for them, so calling one raises an error rather than being
  refused.
- **The knowledge store is one shared, in-process database**, not a second
  server — the Judge and Navigator both query the same live room map. The
  Player never needs to: room info is already pushed into its context every
  turn for free, so a tool to re-ask would just be a round trip to learn
  nothing.
- **Memory only reaches the Player through the Planner**, and only gets
  written on a `replan`/`flag` verdict or a session boundary (`/exit`,
  `/clear`, EOF) — never on a plain `continue`, and never through the
  Player's own tools.

This intentionally leaves out session-compaction details, permission
internals, and file-level wiring — see
[`week3_capable/README.md`](week3_capable/README.md) for those.

<details>
<summary>A real run (captured 2026-08-10, against a live CircleMUD server — $0.02, not staged)</summary>

```text
$ boukensha --no-tui
boukensha> Look around, then try moving in one direction, and tell me what you find.

[planner]
Objective: Scout the immediate area to understand the current location and
available exits.
Steps: 1. Look around the current room. 2. Move in the safest-looking
direction. 3. Look around the new room and report back.
Stop when: You have moved to an adjacent room and reported what you found.

Excellent! I've moved north and found The Great Field Of Midgaard. Here's
what I discovered:

Current Location: The Great Field Of Midgaard
Exits: Only south (back to where I came from)
Description: A beautiful, peaceful countryside with a wide dirt path, lush
green grass, oak trees, and birds.
Obstacle: The path north is blocked — no way around it.

Shall I head back south and try a different direction?
boukensha> /exit
[chronicler] memory updated for dummy.
Goodbye.
```

Two Player turns, two Judge checkpoints (both `continue`), one real memory
digest written on `/exit`:

```markdown
## Discoveries
Started in The Great Field Of Midgaard, a peaceful countryside with wide
dirt path, lush grass, oak trees. Exits: south to Midgaard city. North is
blocked... Only safe exit is south back toward the city.

## Open threads
Explore south toward Midgaard city to find NPCs, shops, or other areas.
```

</details>

## Want to go deeper?

| Path | What's there |
|---|---|
| [`week0_explore/`](week0_explore/CHALLENGES.md) | The very first step — talking to the game over a raw connection |
| [`week1_baseline/`](week1_baseline) | The first working agent, built one lesson at a time |
| [`week2_observability/README.md`](week2_observability/README.md) | The world map, the dashboard, and tracing |
| [`week3_capable/README.md`](week3_capable/README.md) | The full technical write-up of the Plan/Play/Check/Remember loop |
| [`docs/plans/capability/`](docs/plans/capability) | Design docs written before Week 3 was built |
| [`docs/journal/3_capable.md`](docs/journal/3_capable.md) | The engineering journal — what was tried, what surprised, what's still unproven |

## Setup

This section is technical — it's for anyone who wants to actually run the
agent, not required reading otherwise.

### 1. Build & install the gems, in dependency order

`boukensha` spawns `mud-manager` as a subprocess by bare command name, so
both need to resolve on `PATH`:

```sh
cd week0_explore/mud_manager        # or week3_capable/mud_manager
gem build mud_manager.gemspec
gem install ./mud_manager-*.gem

cd ../../week3_capable/boukensha
gem build boukensha.gemspec
gem install ./boukensha-*.gem
```

`week3_capable/bin/rebuild` does both steps for you, in this order.

### 2. Point `boukensha` at this repo's config

By default `boukensha` looks for its config in `~/.boukensha`, not the
repo. Point it at the repo-root `.boukensha/` instead — either per shell
session:

```sh
export BOUKENSHA_DIR="$(pwd)/.boukensha"   # run from the repo root
```

or once, in `~/.boukensharc`:

```yaml
boukensha_dir: /absolute/path/to/this/repo/.boukensha
```

Either way, this is the `.boukensha/settings.yaml` (shared across weeks)
that then actually gets read:

```yaml
tasks:
  player:
    provider: anthropic
    model:    claude-haiku-4-5
    prompt_override:
      system: true

mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:
      MUD_HOST:     localhost
      MUD_PORT:     "4000"
      MUD_NAME:     dummy
      MUD_PASSWORD: helloworld
```

Credentials travel via `env:` here, never through the model's own tool
calls, so the agent itself never sees or sets them.

### 3. `.boukensha/.env` (repo root, git-ignored)

```sh
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
OLLAMA_API_KEY=...
```

### 4. Run

```sh
boukensha              # TUI REPL
boukensha --no-tui     # plain-terminal REPL
```

The character played is whichever `MUD_NAME` is set in
`mcp_servers.mud.env` above.

### 5. Optional: the dashboard

```sh
cd week3_capable/mud_monitor
bundle install
bundle exec ruby bin/mud_monitor   # http://localhost:4568
```

### 6. Optional: turn on Plan / Check / Remember

Off by default, so existing configs keep working unchanged:

```yaml
tasks:
  planner:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
  judge:
    provider: anthropic
    model:    claude-haiku-4-5
    enabled:  true
    every:    3        # check in every 3rd turn
  chronicler:
    provider: anthropic
    model:    claude-haiku-4-5   # required whenever memory is on — Remember
                                  # has no `enabled:` flag of its own, but
                                  # still needs a model to call

memory:
  enabled: true
```

See [`week3_capable/README.md`](week3_capable/README.md) for the full set of
options, including the Navigator.

### 7. Tests

```sh
cd week3_capable/boukensha    && bundle exec rake test
cd week3_capable/mud_manager  && bundle exec rake test
cd week3_capable/mud_monitor  && bundle exec rake test
```
