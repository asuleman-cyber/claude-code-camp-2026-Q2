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