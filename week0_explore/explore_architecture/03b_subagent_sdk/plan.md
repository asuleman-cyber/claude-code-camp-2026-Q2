# Plan: replace filesystem-loaded subagent with `AgentDefinition`

## Current state

Right now the "mud-player" subagent is defined the Claude Code way: a
markdown file with YAML frontmatter at `.claude/agents/play-mud.md`
(name/description/tools in frontmatter, the system prompt as the markdown
body). Claude Code discovers this automatically from the filesystem — there
is no driver script in this directory yet; the agent only exists as
something Claude Code's own subagent loader picks up.

There is no Python driver here today. `scripts/mud_client.py` is just the
headless TCP/telnet client the subagent shells out to — it doesn't touch the
Agent SDK at all.

## Goal

Stop relying on filesystem discovery of `.claude/agents/*.md` and instead
define the same subagent **in code**, using the Claude Agent SDK's
`AgentDefinition`, passed programmatically via `ClaudeAgentOptions(agents={...})`.

## Proposed changes

### 1. New driver script: `scripts/run_mud_agent.py`

A small Python entrypoint using `claude_agent_sdk` that:

- Builds an `AgentDefinition` for `"mud-player"` in code, translating the
  existing `play-mud.md` frontmatter + body 1:1:
  - `description` — copied verbatim from the frontmatter `description` field
    (used for auto-delegation matching).
  - `prompt` — the markdown body of `play-mud.md` (the "MUD Player" system
    prompt: players, how it works, memory loop, usage, notes) as a Python
    string (likely loaded from a `.md` prompt file kept alongside the script,
    or inlined as a triple-quoted string).
  - `tools` — `["Bash", "Read", "Write", "Edit"]`, matching the frontmatter
    `tools:` line.
  - `model` — omitted/`"inherit"` unless we want to pin it.
- Constructs `ClaudeAgentOptions(agents={"mud-player": agent_definition}, ...)`
  and runs a query via `ClaudeSDKClient` (or `query()`), forwarding the
  user's request (e.g. "play the MUD for a bit") to the orchestrator, which
  can then delegate to the `mud-player` subagent exactly as it would have via
  the filesystem-based definition.
- Keeps the same working directory assumptions (`scripts/mud_client.py`,
  `data/player.md`, `data/world.md` resolved relative to this project dir),
  since the subagent's Bash tool still shells out to `mud_client.py`.

### 2. Prompt content source

To avoid duplicating a large prompt inline in Python, extract the current
`play-mud.md` body into a standalone prompt file (e.g.
`scripts/prompts/mud_player_prompt.md`) with no frontmatter, and have
`run_mud_agent.py` read it at startup and pass its contents as
`AgentDefinition.prompt`. This keeps the prompt text easy to edit without
touching Python code.

### 3. `.claude/agents/play-mud.md`

Once the SDK-based definition is the thing actually used to run this agent,
the filesystem file becomes redundant (and could conflict/confuse — Claude
Code would still auto-load it in *this* CLI session even though the new
script bypasses that mechanism entirely). Options:
- **Delete it**, since `scripts/prompts/mud_player_prompt.md` becomes the
  source of truth.
- **Keep it** as a reference/comparison artifact showing "the old way," and
  rely on the SDK script for actual runs.

Leaning toward deleting it, since keeping two copies of the same prompt
invites drift — but flagging this as a decision point rather than assuming.

### 4. Dependencies

- Add `claude-agent-sdk` (Python package) as a dependency — no
  `requirements.txt` exists in this dir yet, so one would need to be added
  (or documented as `pip install claude-agent-sdk`).
- Requires `ANTHROPIC_API_KEY` (or equivalent auth) in the environment to run
  the SDK client, separate from the interactive Claude Code CLI session.

### 5. Testing

- Run `python scripts/run_mud_agent.py "check on the character and play a
  bit"` and confirm:
  - The orchestrator delegates to the in-code `mud-player` agent (not a
    filesystem one).
  - It still correctly shells out to `scripts/mud_client.py` and
    reads/writes `data/player.md` / `data/world.md`.

## Open questions for you

1. Delete `.claude/agents/play-mud.md` once the SDK version exists, or keep
   both?
A:  We want to implmenet a full replacement
2. Is a new `scripts/run_mud_agent.py` entrypoint the right shape, or did you
   want the existing `mud_client.py` itself modified/merged?
A: we want to load a markdown file
3. Any preference on `query()` (one-shot) vs `ClaudeSDKClient` (multi-turn)
   for the driver?
A: interactive loop