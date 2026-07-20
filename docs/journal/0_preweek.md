# Preweek Technical Documentation

## Technical Goal
The technical goal of Preweek Explore is to determine how well do Agent Architectures fit our business use-case.


## Technical Uncertainty

- I'm not sure or knowledgeable about LLM and agentic capabilities just yet.
- Unsure if a model-driven or code-driven loop will help in this non-code project. Sometimes it's hit or miss and the agent reads/writes tasks outside the file folder when not asked to.
- Not enough iterative testing done yet.
- Concerned about memory used with LLM and agent task execution, how will it remember and collect info without forgetting.
- Concerned coding harnesses can't interact with a MUD without an interface or SDK to manage the telnet session.
- Unsure what model is right to accomplish the goal while staying token cost effective and not burning through the token limit.


## Technical Hypothesis
My assumption going in was that generic model memory alone would not be enough to reliably navigate the MUD world - the agent would need a better-architected loop (specialized agentic loop, not just raw prompting) with a proper memory system to hold up over time.

I expected that giving the agent more structure - better SDK/architecture rather than a plain prompt-and-context loop - would make it meaningfully more capable and agentic.

I also expected the telnet communication layer itself to be a source of problems, particularly around managing persistent/live sessions, separate from any issues in the agent's own reasoning or memory.




## Technical Observerations

- Sonnet was the better performer for reasoning. It executed quickly, didn't hesitate or ask for permission it didn't need, and handled ambiguous goals well.
- Connection and tooling reliability was hit or miss across runs. Troubleshooting nc and telnet to ensure local host could load properly into MUD
- When something broke, like a healing action not actually healing, the agent noticed and logged it as a caveat instead of just repeating it blindly. Good sign for self correction.
- The agent showed real judgment around risk. It de-prioritized a fight it wasn't ready for and switched to a safer goal on its own, without me telling it to be cautious.
- It didn't plan multi-step prep on its own, like deciding to grind safe exp, even when that was the obvious next move. Good judgment, but not real forward planning yet.
- Markdown memory works fine at small scale where the coding harness updates simple memory but is already showing friction. Whole sections get rewritten instead of targeted edits, there's no way to query it, and updates only happen at the end of a session.


## Technical Conclusions

**Model choice:** Sonnet was the correct model for the agentic loop, not Haiku. Sonnet engaged with the reasoning better and actually let me get from goal to next steps, whereas Haiku's limitations showed up more as connection/tooling struggles than genuine task reasoning.

**Custom skill was necessary:** A plain prompt-and-context approach wasn't enough to reliably accomplish the goal. Wrapping the connection logic and behavior into a proper Skill made a real difference.

**Plain agent approach (`01_plain_agent`):** The main issue wasn't the agent's reasoning, it was the environment. It burned attempts rewriting connection scripts from scratch instead of reusing a working method, and had no way to persist "how to connect" between runs. Once it did get connected, login and basic navigation worked fine. So the conclusion here is: this approach is viable, but only if the connection problem is solved outside the agent, not left for it to rediscover every time.

**Agent Skills approach (`02_agent_skills`):** This is where judgment showed up. The agent self-assessed risk, changed its own plan when it wasn't ready for a fight, and caught its own mistakes (like a broken heal) without being told to. The gap here wasn't judgment, it was planning. It knew it wasn't ready but didn't take the next step of figuring out how to get ready.

**Autonomy — how it can be achieved:** Based on both experiments, autonomy comes from giving the agent a reliable foundation to act on, not from the model alone. That means a persisted, pre-solved connection method (a mud_manager) so it's not rediscovering basics every run, a proper memory/state system that can scale past simple markdown, and a custom agentic loop that pushes the agent from "recognizing it's not ready" toward actually planning the steps to get ready.


**Filesystem subagent vs SDK-defined subagent (3a vs 3b):** The SDK-defined version is the better approach. Defining the agent in code instead of relying on Claude Code's filesystem auto-discovery gives more control over how it runs, and going with a full replacement instead of keeping both avoids two copies of the same prompt drifting apart. The prompt itself stays in a markdown file so it's still easy to edit. Also chose an interactive loop over one-shot querying, since playing the MUD needs back and forth, not a single fire-and-forget call.


## Key Takeaway
 
The capable model here was Sonnet 5, running most of the week 0 tasks with real judgment and self correction without me needing to guide it at each step. The real bottleneck wasn't the model, it was everything set up around it: such as memory that doesn't scale past markdown, and no clear way for the agent to plan multi-step prep on its own. So this tells me autonomy is really an architecture problem, not a model problem, and the fix is building out that foundation: improve connection interface, real memory and state system, and self improving MUD Player.