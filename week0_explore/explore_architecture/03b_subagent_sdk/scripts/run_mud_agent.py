"""Interactive driver that runs the mud-player subagent via the Claude Agent SDK.

Replaces filesystem discovery of `.claude/agents/play-mud.md` with an
in-code `AgentDefinition` passed to `ClaudeAgentOptions(agents={...})`.
"""

import sys
from pathlib import Path

import anyio
from claude_agent_sdk import (
    AgentDefinition,
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
)

PROJECT_DIR = Path(__file__).resolve().parent.parent
PROMPT_PATH = Path(__file__).resolve().parent / "prompts" / "mud_player_prompt.md"

MUD_PLAYER_DESCRIPTION = (
    'Play the local TBAMUD (DikuMUD/CircleMUD-derived) text MUD server running '
    'at localhost:4000, logging in as player/helloworld and issuing in-game '
    'commands (movement, look, combat, inventory, etc), while tracking '
    'long-running goals like reaching a target level or defeating a specific '
    'monster across many sessions. Use whenever the user asks to play, '
    'explore, grind, level up, hunt something, or check on "the MUD" or their '
    'character/progress in it — even if they only mention the character or a '
    'goal without saying "MUD" explicitly.'
)


def build_options() -> ClaudeAgentOptions:
    prompt = PROMPT_PATH.read_text(encoding="utf-8")
    return ClaudeAgentOptions(
        agents={
            "mud-player": AgentDefinition(
                description=MUD_PLAYER_DESCRIPTION,
                prompt=prompt,
                tools=["Bash", "Read", "Write", "Edit"],
            ),
        },
        cwd=str(PROJECT_DIR),
    )


def print_message(message) -> None:
    if isinstance(message, AssistantMessage):
        for block in message.content:
            if isinstance(block, TextBlock):
                print(block.text)
            elif isinstance(block, ToolUseBlock):
                print(f"[tool call] {block.name}({block.input})")
            elif isinstance(block, ToolResultBlock):
                print(f"[tool result] {block.content}")
    elif isinstance(message, ResultMessage):
        if message.total_cost_usd:
            print(f"[turn cost: ${message.total_cost_usd:.4f}]")


async def main() -> None:
    options = build_options()

    async with ClaudeSDKClient(options=options) as client:
        initial_prompt = " ".join(sys.argv[1:]).strip()

        print("mud-player interactive session. Type 'exit' or 'quit' to stop.")

        while True:
            if initial_prompt:
                user_input = initial_prompt
                initial_prompt = ""
            else:
                try:
                    user_input = input("> ").strip()
                except EOFError:
                    break

            if not user_input:
                continue
            if user_input.lower() in ("exit", "quit"):
                break

            await client.query(user_input)
            async for message in client.receive_response():
                print_message(message)


if __name__ == "__main__":
    anyio.run(main)
