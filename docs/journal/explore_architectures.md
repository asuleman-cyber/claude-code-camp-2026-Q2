# Explore Agent Architectures

## 1. An agent file with referenced files eg. CLAUDE.md, @~/docs/*.MD

I created a CLAUDE.md with a simple prompt telling the agent it's a Player Journey Agent.
I gave it the MUD location, credentials, and told it to manage its own memory via data/player.md and data/world.md.

Goal given: "Find the bakery and list the menu."
Model: Haiku 4.5, effort: high.

### Technical Observations

I found that no `nc`, interactive `telnet`, or PowerShell process spawn worked in my sandboxed environment.
3 of 4 connection attempts failed purely on tool availability, not MUD logic.
The agent eventually found a working method (`bash /dev/tcp`) through trial and error, not because it reasoned toward it.
I watched it write 4 separate scripts, one per failed attempt.
Nothing was reused — each failure triggered a rewrite from scratch instead of a fix.
Once connected, the agent handled the login sequence fine and reached Temple Square, then Market Square.
It discovered a `SHOPS` command via in-game help.
I didn't see the agent go off-task reading unrelated files in this run — the failures were entirely at the transport layer.

### Technical Conclusions

I think the environment itself was my primary obstacle here, not the agent's reasoning.
The networking tools I assumed would be available (per my own HOW_TO_PLAY.md instructions) weren't present or permitted in this shell.
This cost 3 wasted attempts before anything worked.
This tells me two separate things need fixing, not one.
Environment consistency — I need the agent's runtime to have guaranteed access to a working connection method.
Right now success depends on which shell tools happen to exist on whatever machine it's running on, which isn't reproducible or reliable.
Connection reuse — even once a working method was found, the agent had no way to persist that knowledge.
I'd expect it to rediscover it via the same trial-and-error next time.
This confirms I need a persisted MUD interface — a mud_manager — regardless of which specific transport bug I hit.
The deeper problem is that the agent has no memory of "how to connect" that carries between runs.
My takeaway differs slightly from "the model doesn't understand the MUD's login flow."
In my case the model handled login correctly once it had a working socket.

The gap I found was purely infrastructural: give the agent a reliable, pre-solved connection method via mud_manager, and login and navigation appear to work fine even on the smallest model I tested.


## 2. Agent Skills driven by main agent
Model: Sonnet 5

Created a skill that has its own script to connect to the mud, creating skills and reliably connect and play mud as agent (sonnet 5)
Executed quickly and didn't ask permission besides. Found bakery. More can be done for other tasks.
Skill player and world update done. Asked to fight minotaur, the memory files read and its considerate to not fight when killed/nearly killed last which it remembers.
Primary goal achieved (partially) — found the minotaur zone entrance but didn't fight due to priority/safety, didn't ask me anything and followed the md file. It didn't level up or do other things I may have asked, but independently found the newbie zone north of Midgaard.

### Comparison to session 1 (bakery/kick tasks)
- Session 1 (simple/medium tasks): fast, no hesitation, executed and reported.
- Session 2 (broad/dangerous goal): slower, but showed actual judgment — self-preservation over "goal completion at any cost." Closest thing to real prioritization I've seen from it so far.
- Still didn't attempt any kind of leveling/prep loop on its own initiative (e.g. "go kill weak fidos safely to gain exp") even though that's the obvious next step toward its own stated goal — it stopped at "not ready" rather than "here's how I get ready."


### Session 2 — self-directed prep, no explicit instruction to be cautious
- Told it "make defeating the minotaur primary goal and execute" — nothing else specified.
- Read both memory files before acting. Self-assessed as too weak (level 1, unarmed, 13/23 HP) and switched the goal to safe scouting on its own — didn't ask permission, just made the call and explained it after.
- Noticed `rest` wasn't actually healing and logged it as a caveat instead of repeating it blindly.
- Updated world.md with corrections, flagging uncertain info as "unverified" rather than silently overwriting.
- When asked after the fact if it leveled up, gave an accurate answer — no exp, no combat, scouting only. Didn't overstate progress.


## Technical Conclusions

Agent Skills works, and its judgment beat expectations — no "what should I do?" stalling like Andrew hit; it self-assessed risk and changed plans on its own.
Gap: it recognizes "not ready" but doesn't plan how to get ready — stops at scouting instead of deciding to grind exp.
Markdown memory holds at town-scale but is coarse — whole sections rewritten per update, no queryable structure, updates only land end-of-session.
Need real per-action token/usage visibility, not just per-invocation, to actually audit the player journey.
Bottom line: less about stopping the agent from asking questions (mine doesn't), more about giving it multi-step planning instead of stalling at "not ready yet."
