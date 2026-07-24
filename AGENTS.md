# Working in this repo

## Adversarial review loop

Run an **independent, iterative** review at research, plan, and implement stages — not a single self-review pass. Each round: review → log findings → update the artifact → **re-review** until Critical/High issues are closed.

**Full process:** [`docs/superpowers/ADVERSARIAL-REVIEW-LOOP.md`](docs/superpowers/ADVERSARIAL-REVIEW-LOOP.md) (severity levels, verdicts, plan template, anti-patterns, worked example).

- Fix all **Critical** and **High** findings before advancing.
- **PASS WITH NOTES** only when remaining items are explicitly accepted; if the user asks to loop until no issues remain, aim for **PASS (0 open Critical/High)**.
- Plans live under `docs/superpowers/plans/` (Apple: `apps/apple/docs/superpowers/plans/`) and must include an adversarial review section after non-trivial planning.

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

## Testing

- Tests are not required by default. Add or update them when requested, when fixing a regression, or when a change has meaningful risk.
- Do not block feature implementation on tests unless the user explicitly requests TDD or a test-first approach.

## Worker database access

- In `workers/**`, use Drizzle for all database schema access and mutations in application and test code.
- Do not hand-write raw SQL statements in worker application or test code. SQL is limited to generated migration artifacts managed by Drizzle.

## Worker package commands

- In `workers/worker`, always use Bun for dependency installation and project commands: `bun install`, `bun run <script>`, and `bunx <tool>`.
- Do not use Yarn, npm, pnpm, or npx for worker installs or command execution.
