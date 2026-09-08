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

## API compatibility and Apple Worker development

- **STRICT PRODUCTION SAFETY RULE — CHECK EVERY BRANCH BEFORE DEPLOYING:** No agent may deploy a Worker branch to production until it has compared the branch against `origin/main` and verified that every released API route, response/request contract, authentication flow, database contract, binding, and Durable Object protocol remains backward compatible with the production baseline. A successful build or test run is not sufficient evidence. If an existing contract must change, create a new explicitly versioned API/transport route and keep the previous version implemented and deployable for already-installed clients; never modify the old route in place. This check is mandatory on every branch and must be recorded in the plan/review or deployment notes before any `wrangler deploy`.
- **STRICT DEPLOYMENT BLOCK:** If the compatibility check is missing, inconclusive, or identifies a breaking change without a preserved version, do not deploy. Stop and fix the versioning/compatibility problem first. This rule applies to the primary API Worker, sharing Worker, Durable Object classes, migrations, secrets/configuration, and Apple client endpoint changes, and must be followed by all future agents.
- Follow [`docs/superpowers/specs/2026-09-01-api-versioning-and-apple-worker-development-policy-design.md`](docs/superpowers/specs/2026-09-01-api-versioning-and-apple-worker-development-policy-design.md) for all Worker-backed Apple work.
- Treat released unversioned `/api/...` routes as frozen legacy contracts. New API families use `/api/v1/...`; bump the version only for a breaking change to an existing contract, and keep the previous version available for installed clients.
- Treat the existing sharing protocol under `/v1` as a frozen legacy contract too. Never add new Apple/session semantics to the legacy `SessionRoom`, `/v1` routes, or their Durable Object state. New sharing behavior must use a new versioned transport (currently `/v2`) and a separate Durable Object class/binding, with an append-only Wrangler migration; the primary Worker must call that version explicitly.
- The primary Worker's `SHARING_INTERNAL_SECRET` and the sharing Worker's `WORKER_HMAC_SECRET` are one shared trust secret, despite their different names. Before deployment, set both production secrets from the same value; never rotate only one.
- Before testing the Apple app, use the canonical production API Worker and production sharing Worker. Do not start or point Apple builds at the local Worker launcher/configuration.
- Keep one versioned public API Worker across production and development. Do not create a separate dev API Worker or let API contracts diverge. The sharing Worker is only the internal WebSocket service required by shared reading.
- Configure all Apple builds, including Debug, to use the canonical production HTTP and sharing WebSocket endpoints. Keep both URLs centralized; do not add feature-specific endpoint fallbacks or process-environment overrides.
- Check for existing managed Worker and app processes before launching, avoid duplicate instances, record health/version information, and stop processes started for the test when finished.
