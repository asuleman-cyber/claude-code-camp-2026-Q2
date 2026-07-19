# World Memory

Everything learned about the game world across sessions: the map, monsters,
NPCs, shops. The MUD itself has no memory of what you've already figured
out — this file is what saves future sessions from re-exploring rooms or
re-learning "that thing north of the temple is too strong" from scratch.

**Update this whenever a session reveals something new**: a room not
recorded below, a monster encountered, an NPC, a shop, a locked door, a
quest hook. Skip anything already accurately recorded — this file is meant
to stay a clean reference, not a raw transcript. Use `list` while standing
in a shop to record/refresh its wares; prices and stock can change.

## Map

One entry per room actually visited. Keep exits accurate; that's what makes
this useful for navigation instead of blind wandering. Rooms are grouped
loosely by area as they're discovered — reorganize if it stops being useful.

### Temple area

**The Temple Of Midgaard** (character's starting room)
- Exits: n, e, s, w, d
- Notes: ATM (automatic teller machine) here. West = Reading Room
  (unexplored). East = donation room (unexplored). South leads to Main
  Street. `d` and the rest of these exits are still unconfirmed — only
  n and s have actually been walked.

**By The Temple Altar** (north of the Temple)
- Exits: n, s
- Notes: Statue of Odin. North leads out the back of the temple toward the
  countryside (unexplored beyond here).

**Behind The Temple Altar** (north of By The Temple Altar)
- Exits: n, s
- Notes: dirt path leading toward the Dragonhelm Mountains far to the
  north. This is the way to the newbie zone, not "out into the
  countryside" generically.

**The Great Field Of Midgaard** (north of Behind The Temple Altar) — two
rooms share this name/description along the path.
- First room: exits n, s (path continues north).
- Second room (one step further north): exits n, e, s, w — a "strange
  structure" is visible to the east (see The Entrance To The Newbie Zone),
  and a small dirt path splits off to the west (unexplored).

**The Entrance To The Newbie Zone** (east of the second Great Field room)
- Exits: n, w
- Notes: flavor text says "when you've readied yourself you can enter to
  the north" — north from here is the newbie zone itself, presumed
  location of the minotaur (primary goal). **Not yet entered** — character
  was unarmed/unarmored at 13/23 HP when scouted, too risky to push in
  further. Gear up and heal before going north from here.

### City center

**Temple Square** (south of the Temple, north of Market Square) — a room
distinct from Main Street; previously unrecorded. Confirmed path:
Common Square -n-> Market Square -n-> Temple Square -n-> Temple Of
Midgaard.
- Exits: n, e, s, w
- Notes: Clerics' Guild to the west, the old Grunting Boar Inn to the
  east, large bubbling fountain here. Worth checking the Inn and Guild
  for a trainer/weapon shop — not yet explored.

**Main Street** — relationship to the Temple/Market Square not yet
reconfirmed this session (older notes said it was directly south of the
Temple with the bakery/Armory/market square around it, but the actual
south path from the Temple now confirmed to go through Temple Square
instead). Treat the "south of the Temple" claim below as unverified until
re-walked.
- Exits: n, e, s, w
- Notes: bakery to the north, Armory to the south, market square to the
  east.

**The Armory** (south of Main Street) — *equipment shop*
- Exits: n
- NPCs: **an armorer** (shopkeeper — see Shops below), **a Peacekeeper**
  (guard, presumably hostile to fighting in shops — not tested).
- Notes: a small note on the wall, unread.

**The Bakery** (north of Main Street) — *food shop*
- Exits: s
- NPCs: **the baker** (shopkeeper — see Shops below).
- Notes: a small sign on the counter, unread.

**Market Square** (east of Main Street)
- Exits: n, e, s, w
- Notes: a large statue in the middle. North = temple square (per this
  room's own description — not yet confirmed by walking it; may or may not
  be the same as "By The Temple Altar" above). South = Common Square. East/
  west = main street.

**The Common Square** (south of Market Square)
- Exits: n, e, s, w
- Notes: west = poor alley (unexplored), east = dark alley, south has "a
  nasty smell" (unexplored, likely sewers). **Danger:** see Monsters below
  — do not fight here below at least level 3-4.

### Levee district (east of Common Square)

**The Dark Alley At The Levee**
- Exits: e, s, w
- Notes: confirmed route: Levee -n-> here -w-> The Dark Alley -w->
  Common Square. So Common Square's "east = dark alley" leads here via
  one intermediate room.

**The Dark Alley** (between The Dark Alley At The Levee and Common Square
— distinct room, easy to confuse with the one above)
- Exits: e, s, w
- NPCs: **a Peacekeeper** (guard), **5 mercenaries** "waiting for a job"
  (hireable escorts/muscle? — not tested).
- Notes: Guild of Thieves is to the south (unexplored). West = Common
  Square, east = Dark Alley At The Levee.

**The Levee** (south of Dark Alley At The Levee)
- Exits: n, s
- NPCs: **a retired captain**, sells boats (wares not yet checked with
  `list`).
- Notes: river flows west just south of here; bank is low enough to enter
  the river. `drink water` here fails ("You can't find it!") — a water
  source exists somewhere but this isn't it; still need to find one (try
  actually entering the river, or check other areas — e.g. the Temple's
  unexplored east/west rooms, or ask an NPC).

## Monsters

| Monster | Location | Notes | Defeated? |
|---|---|---|---|
| A beastly fido | The Common Square (3 present) | Weak alone (missed/tickled each other repeatedly at level 1), but **a cityguard in the same room aggressively assists it** and hits hard — took the character from 23 HP to 13 HP in a couple of rounds. Fled rather than risk death. Do not re-engage here without more HP or a way to avoid drawing the guard in. | No — fled |
| Massive minotaur (primary goal) | Somewhere north of "The Entrance To The Newbie Zone" (further north of the Great Field Of Midgaard, north of the Temple). Not yet sighted — zone itself not yet entered. | Presumably far too strong for an unarmed/unarmored level 1 — get gear and levels first. | No — not yet engaged |

## NPCs & shops

Shopkeepers respond to `list` (see wares) and presumably `buy <item>` /
`sell <item>` (not yet tested).

**The armorer** — The Armory. Sells armor:

| # | Item | Cost |
|---|---|---|
| 1 | A pair of leather sleeves | 90 |
| 2 | A pair of bronze sleeves | 210 |
| 3 | A pair of leather pants | 180 |
| 4 | A pair of bronze leggings | 420 |
| 5 | A leather cap | 180 |
| 6 | A bronze helmet | 420 |
| 7 | A pair of leather gloves | 90 |
| 8 | A pair of bronze gauntlets | 210 |
| 9 | A bronze breast plate | 840 |
| 10 | A scale mail jacket | 1200 |
| 11 | A studded leather jacket | 600 |
| 12 | A leather jacket | 240 |
| 13 | A shield | 120 |
| 14 | A chain mail shirt | 300 |
| 15 | A breast plate | 216 |

Cheapest starter set (leather sleeves + pants + cap + gloves + shield):
90+180+180+90+120 = 660 gold. Character currently has 0 gold — need an
income source (kills, quests, or the bank/ATM back at the Temple) before
buying anything here.

**The baker** — The Bakery. Sells food:

| # | Item | Cost |
|---|---|---|
| 1 | A danish pastry | 7 |
| 2 | A bread | 14 |
| 3 | A waybread | 70 |

Cheap and covers the "find food" goal once there's any gold at all.

**A retired captain** — The Levee. Sells boats. Wares not yet listed.

## Open questions / still need to find

- **Weapon shop** — not located yet. The armory sells armor/shields only,
  no weapons. Probably somewhere off Main Street or Market Square that
  hasn't been explored (Market Square's own east/west main-street exits
  toward other blocks, or Common Square's unexplored west/south exits).
- **Guildmaster / practice trainer** — needed to spend practice sessions on
  skills like `kick`. Not located yet. In stock CircleMUD-style worlds
  these are usually near the starting temple or in a class-specific guild
  building; worth checking the Temple's unexplored east/west/down exits
  first.
- **Reliable water source** — `drink water` failed at the Levee despite the
  river being right there. Try actually entering the river, or check for a
  well/fountain elsewhere — Temple Square has a fountain, worth trying
  (`drink fountain`?) next session.
- **Weapon shop / trainer** — the old Grunting Boar Inn and Clerics' Guild
  at Temple Square (newly found this session) haven't been checked yet;
  good next candidates before assuming a weapon shop is elsewhere.
