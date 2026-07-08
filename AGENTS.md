# Working in this repo

## Use a subagent-driven / agent-team approach

Delegate work to subagents (the Agent tool) or agent teams rather than doing it
directly in the main session. Dispatch research, exploration, and multi-step
implementation to the appropriate agent type, and run independent work in
parallel.

**Why:** Doing the work directly fills the main context with tool output (file
reads, search results, build logs) and crowds out the conversation. Subagents do
the heavy lifting in their own context and report back a concise result, keeping
the main thread clean and coherent over long sessions.

**How to apply:**
- Default to dispatching tasks to subagents instead of running the tools yourself.
- Use parallel subagents when tasks are independent (one message, multiple Agent calls).
- Reserve the main context for synthesis, decisions, and talking to the user.
