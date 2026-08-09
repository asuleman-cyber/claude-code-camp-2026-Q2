# Week 1 Technical Documentation

## Technical Goal
Build a baseline agent to play tbaMUD with a custom architecture — no Agent SDK, no coding harness — that covers all the basic parts an agent needs: a loop, a tool registry, a way to swap LLM backends, logging, a DSL-style entry point, a global CLI binary, and its own config directory. I followed the video step-by-step in Ruby (`00_config` through `12_context`) and mirrored most of it in Python at the same time, since I wanted to see the same ideas expressed twice instead of just copying one language.

## Technical Uncertainty
- I wasn't sure doing Ruby and Python side by side every step was a good use of time versus just picking one and going deep — I worried I'd end up half-finishing both.
- I wasn't sure I needed all five LLM backends (Anthropic, OpenAI, Gemini, Ollama, Ollama Cloud) wired up when I was really only ever testing against one model (Claude Haiku 4.5). I left the others configured but commented out in `settings.yaml` rather than actually comparing them.
- The video told me MCP was a "watch, don't build" step, so I wasn't sure whether I could get away with skipping it — I only found out I couldn't once Python had no way to talk to the Ruby `MudManager` at all.
- I wasn't sure how much of my "it's not working" moments were Windows-specific plumbing problems versus something actually wrong with the agent's logic, since I kept hitting things (paths, gem builds) that had nothing to do with the agent itself.
- I wasn't sure whether building my own log viewer (`log_viz`) instead of just reading the terminal was worth the detour, or whether it was procrastination dressed up as tooling.

## Technical Hypothesis
- I assumed following the steps in order, one at a time, would make the whole thing feel mechanical rather than something I actually understood — I was wrong, having to re-explain each step to myself in a second language (Python) is what made it stick.
- I assumed skipping the MCP video step would be fine for a while, since the instructions said not to build it. I expected to hit a wall the moment I needed one language to use the other's tools, and that's exactly what happened.
- I assumed Windows would cause more friction than the actual agent code, based on how preweek went, so I expected to spend real time on paths and environment stuff rather than agent behaviour.
- I assumed that once the scaffolding (loop, registry, logging) was in place, the agent would basically "just work" for simple MUD commands, and any real problems would only show up once I gave it open-ended goals — I never got that far this week, so I can't confirm or deny that yet.

## Technical Observations
- The very first Python step broke on Windows because the launcher script assumed a Linux-style venv path (`.venv/bin/python`); Windows puts it at `.venv/Scripts/python.exe`. Small fix, but it was a reminder that "cross-platform" isn't free just because Python is supposedly portable.
- The MCP step really was necessary and not optional in practice. The instructor's note said "watch, don't build" — but the moment I wanted Python to call the same MUD tools Ruby was using, there was no bridge between them without it. That ended up being my single biggest commit of the week ("Huge refactor bringing in MCP and Mud manager log dashboard") because it touched almost everything downstream of it.
- Building `log_viz` (a small local web app to browse the session JSONL logs) early turned out to matter more than I expected — once real sessions started producing malformed or partial log lines, I already had a viewer in place I could go harden, instead of trying to debug raw JSONL in a terminal.
- I never rigorously tested the other backends (OpenAI, Gemini, Ollama) against each other — they're configured in `settings.yaml` but commented out, and everything I actually ran this week was on Claude Haiku 4.5. So I built the "swap backends" capability but didn't validate that it changes anything in practice.
- Packaging each step as an installable gem (`gem build` / `gem install`) so the `boukensha` command works from anywhere was fiddlier than expected on Windows, and I ended up skipping that packaging step for the Python side entirely rather than fight it twice.
- By the end of the week (TUI + context management steps) I had a working terminal UI, token tracking, and auto-compaction on top of the MCP tool model — but I spent the week validating that the plumbing works (loop runs, tools dispatch, logs get written, context compacts) rather than testing whether the agent is actually any good at playing the MUD with an open-ended goal.

## Technical Conclusions
- Doing Ruby and Python in parallel was worth it, not because I needed two working agents, but because problems that were invisible in Ruby (like the venv path assumption) only showed up once I tried the same step in Python on Windows. Redoing the same step twice caught bugs a single pass wouldn't have.
- "Skip this, just watch the video" advice doesn't hold once your own setup needs the thing being skipped. MCP became mandatory the moment I had two languages that both needed the same MUD connection.
- A log viewer isn't a nice-to-have once you're relying on an LLM's tool calls to do the right thing — reading raw JSONL to figure out what actually happened during a run doesn't scale, even at this small a stage.
- I still don't know if my baseline agent is actually good at playing the MUD. Everything I validated this week was structural (does the loop run, do tools dispatch, do logs write, does context compact) rather than behavioural (does it make sensible decisions toward a goal). That's an open question for next week, not something I can claim yet.
- Most of my real struggles this week were environment/plumbing issues (Windows paths, gem builds, missing bridge between two languages) rather than the agent's reasoning being wrong — similar to what I noticed in preweek. I don't have enough evidence yet to say anything about how well the agent itself reasons.

## Key Takeaway
Most of what I fought this week wasn't the agent being "dumb" — it was the scaffolding around it: Windows path assumptions, packaging a gem on the wrong OS, and one language having no way to reach the other's tools until I built the MCP bridge I was told I could skip. Doing the same steps in two languages turned out to be the thing that surfaced those problems, not a waste of time like I worried it might be. What I haven't done yet is actually test the agent against an open-ended goal — this week proved the pipes are connected, not that what flows through them is good.
