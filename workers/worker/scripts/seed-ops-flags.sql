-- One-time seed for the `ops_flag` table (workers/worker/src/db/schema.ts).
-- NOT run automatically by any migration or by application code. Apply by
-- hand, once per environment, via:
--
--   cd workers/worker
--   npx wrangler d1 execute rishi --local  --file scripts/seed-ops-flags.sql
--   npx wrangler d1 execute rishi --remote --file scripts/seed-ops-flags.sql
--
-- `INSERT OR IGNORE` makes this safe to re-run: a flag that's already been
-- seeded (or that an operator has since toggled via /ops/flags) is left
-- untouched. See workers/worker/src/ops/feature-flags.ts for what each key
-- gates and why each default below was chosen — the defaults here MUST
-- match FLAG_DEFAULTS in that file, since FLAG_DEFAULTS is what's used if
-- this seed hasn't been run yet in some environment.
INSERT OR IGNORE INTO `ops_flag` (`key`, `enabled`, `updated_at`) VALUES
	('shadow_accounting', true, unixepoch('now') * 1000),
	('public_trial_available', false, unixepoch('now') * 1000),
	('paid_limit_enforcement', true, unixepoch('now') * 1000),
	('voice_chat_available', false, unixepoch('now') * 1000),
	('ai_kill_switch', false, unixepoch('now') * 1000);
