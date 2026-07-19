# Player Memory — `player`

Persistent memory for this character across MUD sessions. Every session is a
fresh, short-lived connection (see SKILL.md), so this file — not the game
client — is what carries goals and progress from one session to the next,
and from one conversation to the next.

**Read this before playing** to recall where things stand and what to do
next. **Update it after playing**, every session, even a short one.

## Current status

_Overwrite these values in place with the latest known truth — don't append
history here, that's what the log below is for._

- Level: 1 (Swordpupil)
- Class: Warrior
- HP / Mana / Move: 13/100/58 (max 23/100/85) — HP did not recover during
  this session (see strategy notes: resting doesn't visibly heal within a
  single short connection); still needs to actually heal before any fight
- Location: The Entrance To The Newbie Zone (see `world.md` for the map) —
  scouted this far, did not enter the zone itself
- Gold: 0
- Inventory: empty; no equipment worn
- Exp: 1 (need 1999 more for level 2)
- Last updated: 2026-07-19

## Goals

Long-running objectives that should drive what commands to send, rather than
wandering aloofly. Check these off as they're met; add new ones as they come
up. These aren't independent — sequence them sensibly (e.g. get a weapon
before picking fights, don't grind exp at 13/23 HP).

- [ ] **Defeat the minotaur in the newbie north zone of Midgaard.** Primary
      goal — take priority over the other goals below when choosing what to
      do next. Route confirmed: Temple -> n (Altar) -> n (dirt path) -> n
      (Great Field) -> e (Entrance To The Newbie Zone) -> n (zone itself,
      not yet entered). Still too weak to go in — unarmed, unarmored, and
      HP not fully recovered. Get a weapon and heal up before entering.
- [ ] **Reach level 7.** Currently level 1, 1/2000 exp toward level 2. This
      is the long pole — everything else below should generally happen
      along the way, not instead of it.
- [ ] **Earn enough practice sessions to learn kick.** Practice sessions are
      typically granted on level-up and spent with a guildmaster/trainer
      NPC via the `practice` command. No trainer has been located yet —
      see `world.md`'s "Open questions" section. Until one is found, this
      goal is blocked on exploration, not on grinding.
- [ ] **Find reliable food and water.** Food: solved — the Bakery (see
      `world.md`) sells danish/bread/waybread for as little as 7 gold.
      Water: unsolved — `drink water` failed at the Levee despite the
      river being right there; still need to find a working source.
- [ ] **Get basic equipment** (at least a weapon and some armor — currently
      fighting bare-handed with nothing worn). Armor: the Armory (see
      `world.md`) has a full list, cheapest useful set ~660 gold. Weapon:
      no weapon shop located yet. Both are blocked on having gold, which
      is blocked on safely killing something — so in practice this goal
      and the level-7 goal are the same grind.

## Strategy notes

_Freeform space for what's working / not working — e.g. "rats near the
temple square are easy exp, the crypt to the north has something that hits
much harder than level 1 can handle, avoid until higher level."_

- No monsters spawn in the Temple itself — need to head out to find
  anything to fight.
- **Do not fight in The Common Square at low level.** 3 fidos there looked
  easy (both sides mostly missed/tickled), but a cityguard in the room
  aggressively jumps in to help the fido and hits hard — 10 damage in a
  couple of rounds took the character from 23 HP to 13 HP. Fled rather than
  risk death. Need either more HP, a weapon, or a way to fight without
  drawing the guard's attention before trying again.
- The character is currently unarmed and unarmored — that's almost
  certainly why the fido fight went so badly (missed constantly). Getting
  even a cheap weapon before the next fight matters more than finding a
  "safer" monster.
- The `mud_client.py` script now flees automatically if `quit` is refused
  because the character is fighting (see SKILL.md) — this used to be a real
  risk (a session ended while still in combat) but is fixed now.
- `rest` does not visibly restore HP within one short session — HP stayed
  at 13 across an entire connection despite resting and then walking
  several rooms. Regen may require a real-time tick threshold that a quick
  session doesn't reach. Don't assume a session automatically heals the
  character; may need to explicitly `rest` and then send filler commands
  over a longer stretch, or accept partial HP and play conservatively.

## Progress log

_Append-only, newest entry at the bottom. One line per notable event: level
gained, monster killed or fled from, death, quest step, item found. Keep
entries short — this is a log, not a transcript._

- 2026-07-19: Confirmed starting state — level 1 Warrior, 0 gold, 1 exp,
  empty inventory, standing in the Temple. No monsters in the Temple room
  itself.
- 2026-07-19: Explored Main Street, the Armory, the Bakery, Market Square,
  and the Common Square. Found the Armory (armor shop) and Bakery (food
  shop) — see `world.md` for price lists. Attacked a fido in the Common
  Square; a cityguard assisted it and dropped HP from 23 to 13. Fled to The
  Dark Alley At The Levee, then rested. Ended the session resting at 13/23
  HP, 1 exp, 0 gold, at The Levee. Weapon shop, guildmaster/practice
  trainer, and a working water source were not found this session.
- 2026-07-19 (session 2): User set/confirmed the primary goal — defeat the
  minotaur in the newbie zone north of Midgaard. Scouted a safe path there
  without fighting anything: Levee -> Dark Alley At The Levee -> The Dark
  Alley (Peacekeeper + 5 mercenaries, new room) -> Common Square (3 fidos,
  avoided) -> Market Square -> Temple Square (new room, unexplored Inn and
  Clerics' Guild) -> Temple -> Altar -> dirt path -> Great Field Of
  Midgaard -> The Entrance To The Newbie Zone. Did not enter the zone
  itself — still unarmed, unarmored, and at 13/23 HP, no gold. HP did not
  recover despite resting. No fights this session. See `world.md` for the
  full corrected map.
