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

## Worker database schema and migrations

- Drizzle schema files are the source of truth for every database object used by the Worker:
  - D1 schema: `workers/worker/src/db/schema.ts`, configured by `workers/worker/drizzle.config.ts`.
  - Durable Object ledger schema: `workers/worker/src/durable-objects/user-usage-ledger/schema.ts`, configured by `workers/worker/drizzle-do.config.ts`.
- Before changing a table or column, cross-reference the relevant schema file, migration history, runtime queries, tests, and `wrangler.jsonc` bindings. Every live table/column must be represented in its Drizzle schema unless it is explicitly documented as an intentional external/legacy object.
- Never delete or reset a migration directory because it appears old or redundant. Migration files are append-only history for databases that may already contain production data. Removing or renaming them can cause an already-existing table to be recreated. If migration history is inconsistent, repair the history deliberately and verify it against the database before applying anything.
- Never hand-author migration SQL. Run the appropriate Bun command from `workers/worker`:
  - D1: `bunx drizzle-kit generate --config=drizzle.config.ts`.
  - Durable Object ledger: `bunx drizzle-kit generate --config=drizzle-do.config.ts`.
  Commit the generated SQL and metadata together. Do not edit generated migration SQL by hand.
- `drizzle-kit generate` creates migration artifacts; it does not apply them. Apply D1 migrations with the repository's Wrangler/D1 migration workflow. Durable Object migrations are bundled through `drizzle/ledger-do-migrations/migrations.js` and applied by the Drizzle Durable SQLite migrator at DO initialization.
- Do not add runtime `PRAGMA`, `CREATE TABLE`, `ALTER TABLE`, or `DROP TABLE` fallbacks to compensate for missing migration history. Add the field/table to the Drizzle schema, generate the migration, register generated Durable Object migrations in `migrations.js` when required, and let the migrator apply it.
- Keep the two database domains separate: D1 tables in `src/db/schema.ts` are not Durable Object tables, and ledger tables in the DO schema must not be added to the D1 schema merely to make them visible.
- Drizzle `sql` expressions are allowed for parameterized calculations/conditions in queries; they are not a substitute for schema migrations and must not contain hand-written DDL.

## Worker package commands

- In `workers/worker`, always use Bun for dependency installation and project commands: `bun install`, `bun run <script>`, and `bunx <tool>`.
- Do not use Yarn, npm, pnpm, or npx for worker installs or command execution.
