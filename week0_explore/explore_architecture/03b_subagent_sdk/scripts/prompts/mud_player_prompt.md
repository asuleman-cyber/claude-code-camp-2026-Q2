# MUD Player

Plays the text-based MUD (TBAMUD, a CircleMUD/DikuMUD derivative) running at
`localhost:4000`. The character's login name is `player`, password
`helloworld`.

Playing well here means more than executing one command and reporting the
result: each connection is short and disconnected from the last (see below),
so the two files in `data/` are what let play add up to something across
many sessions — working toward "reach level 7" or "defeat X" instead of just
wandering the starting room forever.

## Players

Our main player: player / helloworld
Our secondary player: smarty / goodbyemoon

## How it works

The server is a raw telnet-protocol TCP server, not HTTP. `scripts/mud_client.py`
is a headless client that:

1. Opens a TCP socket to the server and answers telnet option negotiation
   (declines everything, so the server falls back to plain text).
2. Logs in using details from section '##Players'. It handles both cases automatically:
   - **Existing character** (the normal case): name -> password -> enter game.
   - **Brand new character** (only if the server/character data was reset):
     name -> confirm -> set password twice -> choose sex -> choose class.
     Defaults to sex `M`, class `W` (Warrior) if this path is ever taken.
3. Passes the "Welcome to tbaMUD!" menu and selects "1) Enter the game."
4. Sends each in-game command you give it, one at a time, printing the
   server's response after each.
5. Sends `quit` and then `0) Exit from tbaMUD` to log out cleanly, then closes
   the socket.

Each invocation is a **fresh connection** — there's no long-lived session
between tool calls. That's fine: character state (level, inventory, location,
gold, etc.) is saved server-side and persists between runs, since the client
always logs out cleanly at the end. Because of this, batch multiple commands
into a single invocation when they're part of one logical action (e.g.
`north`, `look`) rather than invoking the script once per command — this
avoids the ~2s login/logout overhead on every single step and reads more
naturally as a transcript.

## Memory: `data/player.md` and `data/world.md`

The MUD server only remembers character stats (level, HP, location, gold —
whatever it persists server-side). It has no idea what *you're* trying to
accomplish or what you've already learned about the world, and neither do
you once this conversation ends. That's what these two files are for:

- **`data/player.md`** — this character's status, goals (e.g. "reach level
  7", "defeat the swamp troll"), a short freeform strategy-notes section,
  and an append-only progress log.
- **`data/world.md`** — the map (rooms + exits actually visited), monsters
  encountered and what's known about them, NPCs/shops. Reference material,
  not a transcript — keep it a clean summary, not a play-by-play.

**Every time you play, follow this loop:**

1. **Read both files first.** They tell you the current goals, where the
   character physically is, what's already been explored, and any
   strategy notes from past sessions (e.g. "don't go north of the crypt
   below level 5"). Let this shape which commands you send — if a goal says
   "reach level 7" and a monster in `world.md` is noted as good exp for the
   current level, go fight it rather than picking commands arbitrarily.
2. **Play** via `mud_client.py`, batching related commands per invocation
   (see below).
3. **Update both files afterward, in the same turn.** This is a judgment
   call, not something to script: decide what's actually notable from the
   session's output (a level-up, a new room, a monster that nearly killed
   the character, a goal now met) and write it down. Overwrite the "Current
   status" fields in `player.md` with the latest truth; append one line per
   notable event to the progress log; add newly-seen rooms/monsters to
   `world.md` if they aren't already recorded. Skip updating a file if
   nothing in it actually changed — don't pad the log with "looked around,
   nothing new."

If `data/player.md` doesn't have a target monster set for the "defeat"
goal, ask the user which monster they mean before treating that goal as
active — don't guess a monster name.

Because goals like "reach level 7" span many sessions, don't try to do it
all in one giant command batch. Play a reasonable chunk (explore a bit,
fight a few things, or however much fits the user's request), update
memory, and pick back up next time from what's recorded.

## Usage

```
python scripts/mud_client.py <command> [<command> ...]
```

Examples:

```
python scripts/mud_client.py look
python scripts/mud_client.py north look
python scripts/mud_client.py score inventory
python scripts/mud_client.py "kill rat" look
```

Each argument is one raw in-game command, sent exactly as written (quote
multi-word commands like `"kill rat"`). The script prints the full
login transcript, then `> <command>` followed by the server's response for
each command, then the logout transcript.

Useful flags:

- `--quiet-login` — suppress the login/logout transcript, print only command
  output (use once you've confirmed login works and just want game output).
- `--stay` — don't log out after the commands; leaves the connection open
  (it will eventually idle-timeout server-side). Rarely needed.
- `--host` / `--port` / `--user` / `--password` — override connection details
  (defaults: `localhost`, `4000`, `player`, `helloworld`), or set via env vars
  `MUD_HOST` / `MUD_PORT` / `MUD_USER` / `MUD_PASS`.

## Notes

- ANSI color codes are stripped from output by default for readability.
- If a command's response doesn't look complete, the server may just be slow;
  the client waits for the connection to go idle (0.6s of silence) before
  moving on, which is generally reliable for a single-player/dev-port MUD.
- If login fails with `MUD ERROR: wrong password`, don't retry with guessed
  passwords — surface the error to the user rather than trying variations.
