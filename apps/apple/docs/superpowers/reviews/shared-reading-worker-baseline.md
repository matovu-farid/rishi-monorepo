# Shared Reading Worker Compatibility and Production Baseline

Observed at: `2026-09-16T06:14:38Z`

```ts
const migrationDecision = {
  databaseId: "970159b7-ca91-49c1-bae8-feb43b24a7e6",
  observedAt: "2026-09-16T06:14:38Z",
  head: "2e96f635cbaaf6e7f1e3c2691e5d76d5ad0c8c1b",
  originMain: "70557b0631bff63e495d2dd3244b1da5950a5cc1",
  path: "physical-reconciliation",
  deploymentAllowed: false,
} as const;
```

The production database already contains the complete non-null `session_invites`
shape, all five expected indexes, both historical migration records, 22 rows,
zero null idempotency keys, and zero duplicate owner/key pairs. No migration or
deployment command was run. W1 must prove a generated canonical no-op against an
isolated schema-only clone; it must not replay either historical migration.

## Released HTTP contracts at `origin/main`

Every entry below is `UNCHANGED_VERIFIED` unless marked `COMPATIBLE_DELTA`.
The verification is source/diff compatibility verification; behavioral gates
remain required before rollout.

### Primary Worker

- `GET /` — `UNCHANGED_VERIFIED`.
- Better Auth handler family under `/api/auth/*` — `UNCHANGED_VERIFIED`.
- `POST /api/auth/delete-user` — `UNCHANGED_VERIFIED`; the feature adds bounded
  shared-session revocation behind the existing deletion contract, so its
  internal cleanup is `COMPATIBLE_DELTA`.
- `GET /api/sync/changes/` — `UNCHANGED_VERIFIED`.
- `POST /api/sync/push`, `GET /api/sync/events`, `GET /api/sync/pull` —
  `UNCHANGED_VERIFIED`.
- `POST /api/sync/upload-url`, `POST /api/sync/download-url` —
  `UNCHANGED_VERIFIED`.
- `GET|PATCH|DELETE /api/user/` — `UNCHANGED_VERIFIED`.
- `GET /api/shares/preview`, `POST /api/shares/`,
  `POST /api/shares/prepare`, `POST /api/shares/redeem` —
  `UNCHANGED_VERIFIED`.
- `POST|GET /api/sync/conversations/` and
  `POST|GET /api/sync/messages/` — `UNCHANGED_VERIFIED`.
- `POST /auth/google`, `POST /auth/apple`, `POST /auth/refresh`,
  `POST /auth/verify`, `POST /auth/verify-transaction` —
  `UNCHANGED_VERIFIED`.
- `POST /desktop/start`, `POST /desktop/start/complete`,
  `POST /desktop/poll`, `POST /desktop/cancel` — `UNCHANGED_VERIFIED`.
- `POST /mobile/start`, `POST /mobile/start/complete`,
  `GET /mobile/start/complete`, `POST /mobile/start/verify` —
  `UNCHANGED_VERIFIED`.
- `GET /api/voice-sessions/:id/control`, `POST /api/voice-sessions/`,
  `POST /api/voice-sessions/end-active`,
  `POST /api/voice-sessions/:id/end`, and
  `POST /api/voice-sessions/:id/register-call` — `UNCHANGED_VERIFIED`.
- `POST /api/devices/register`, `POST /api/chat/`, and
  `POST /api/ai/chapter-summaries/` — `UNCHANGED_VERIFIED`.
- `GET /api/groupID` — `UNCHANGED_VERIFIED`.
- `GET /api/billing/me`, `POST /api/billing/verify-receipt`,
  `POST /api/billing/apple-webhook`,
  `POST /api/billing/entitlement-sync`, `POST /api/billing/portal`,
  `POST /api/billing/start`, and `POST /api/billing/realtime-usage` —
  `UNCHANGED_VERIFIED`.
- `GET /health`, `POST /api/audio/speech`,
  `GET /api/audio/speech/options`, `POST /api/audio/speech/elevenlabs`,
  `POST /api/audio/transcribe`, `POST /api/text/completions`, and
  `POST /api/embed` — `UNCHANGED_VERIFIED`.
- Hard-gated test/ops contracts `POST /test/sign-in`,
  `DELETE /test/users/:email`, `GET /test/billing-gate-check`,
  `GET /ops/flags/`, and `POST /ops/flags/:key` — `UNCHANGED_VERIFIED`;
  production continues to omit their enabling variables/secrets.
- New `/api/v1/reading-sessions/**` routes — `COMPATIBLE_DELTA`; they are
  additive and must not alter any released unversioned `/api` route. The exact
  family is:
  - `POST /api/v1/reading-sessions/`
  - `POST /api/v1/reading-sessions/redeem`
  - `GET /api/v1/reading-sessions/active`
  - `GET /api/v1/reading-sessions/:id`
  - `GET /api/v1/reading-sessions/:id/turn`
  - `POST /api/v1/reading-sessions/:id/book-ready`
  - `POST /api/v1/reading-sessions/:id/rejoin`
  - `POST /api/v1/reading-sessions/:id/start`
  - `POST /api/v1/reading-sessions/:id/end`
  - `POST /api/v1/reading-sessions/:id/leave`
  - `POST /api/v1/reading-sessions/:id/controller/transfer`
  - `POST /api/v1/reading-sessions/:id/participants/remove`
  - `POST /api/v1/reading-sessions/:id/participants/restore`
  - `POST /api/v1/reading-sessions/:id/email`

### Sharing Worker

- `GET /health` — `UNCHANGED_VERIFIED`.
- `POST /v1/sessions` — `UNCHANGED_VERIFIED`.
- `POST /v1/sessions/:id/redeem` — `UNCHANGED_VERIFIED`.
- `POST /v1/users/search` — `UNCHANGED_VERIFIED`.
- `GET /v1/sessions/:id/wss` — `UNCHANGED_VERIFIED`.
- Existing `/v1` `SessionRoom` WebSocket messages, token formats, ICE relay,
  roster, approval, progress, reconnect, and terminal-state behavior —
  `UNCHANGED_VERIFIED` and frozen.
- New Apple `/v2` HTTP/WebSocket/internal command family — `COMPATIBLE_DELTA`;
  it is routed only to the separate `AppleSessionRoom` class/binding. No Apple
  command or state is added to `/v1` or `SessionRoom`.

## Authentication and authorization contracts

- Primary Worker Better Auth handler, bearer-session middleware, Apple sign-in,
  refresh/verify flows, deletion authorization, AI-data-consent gate, active
  subscription gate, and ledger admission are `UNCHANGED_VERIFIED`.
- Primary test auth remains fail-closed unless all dedicated non-production
  controls are enabled; production config contains none of them —
  `UNCHANGED_VERIFIED`.
- Sharing `/v1` resolves production auth through `AUTH_BASE_URL`; the optional
  `TEST_AUTH_ALLOWED` shortcut remains absent in production —
  `UNCHANGED_VERIFIED`.
- Primary-to-sharing trust adds the paired `SHARING_INTERNAL_SECRET` /
  `WORKER_HMAC_SECRET` contract for `/v2/internal` only — `COMPATIBLE_DELTA`.
  A one-sided secret rotation is forbidden.

## D1 schema contracts at `origin/main`

All listed tables are `UNCHANGED_VERIFIED`:

`user`, `usernames`, `apple_users`, `account`, `user_api_usage`, `books`,
`share_packages`, `share_package_items`, `share_package_redemptions`,
`share_link_slots`, `chapter_indexes`, `chapter_index_chapters`, `sync_meta`,
`sync_events`, `highlights`, `conversations`, `bookmarks`, `messages`,
`book_pages`, `book_words`, `book_paragraphs`, `session`, `verification`,
`passkey`, `subscription`, `apple_subscriptions`, `apple_notifications_log`,
`retained_apple_entitlement`, `retained_apple_transaction`,
`restored_apple_entitlement`, `deletion_state`, `devices`, `trial_grant`,
`allowance_period`, `usage_reservation`, `usage_audit_log`, and `ops_flag`.

All explicit indexes are `UNCHANGED_VERIFIED`:

`share_packages_recipient_status_idx`,
`share_packages_sender_idempotency_uniq`, `share_packages_token_hash_uniq`,
`share_package_items_package_id_idx`,
`share_package_redemptions_package_user_uniq`,
`share_package_redemptions_package_id_idx`,
`share_link_slots_owner_book_access_uniq`, `share_link_slots_owner_book_idx`,
`share_link_slots_active_package_idx`, `chapter_indexes_user_updated_idx`,
`chapter_indexes_version_key_uniq`,
`chapter_index_chapters_version_chapter_uniq`,
`chapter_index_chapters_version_order_idx`, `sync_events_user_sequence_idx`,
`sync_events_user_operation_idx`, `conversations_user_updated_idx`,
`messages_conv_updated_idx`, `apple_subscriptions_user_id`,
`apple_subscriptions_original_txn`,
`retained_apple_entitlement_identity_uniq`,
`retained_apple_transaction_key_uniq`,
`restored_apple_entitlement_key_uniq`, `devices_user_token_uniq`,
`allowance_period_user_id`, `allowance_period_user_period_start_uniq`,
`usage_reservation_user_id`, and `usage_audit_log_user_id`.

Production-observed `session_invites` is `COMPATIBLE_DELTA`: columns are
`id`, `owner_user_id`, `session_id`, `source_book_id`, `content_hash`, `format`,
`token_hash`, `status`, `created_at`, nullable `ended_at`, and non-null
`idempotency_key`. Its indexes are
`session_invites_owner_idempotency_uniq`,
`session_invites_owner_status_idx`, `session_invites_session_id_uniq`,
`session_invites_source_book_id_idx`, and `session_invites_token_hash_uniq`.

The three production-observed child tables are also `COMPATIBLE_DELTA`:

- `session_invite_items`: `id`, non-null `invite_id`, non-null `file_r2_key`,
  nullable `cover_r2_key`, non-null `file_hash`, non-null integer `file_size`,
  and non-null integer `created_at`; foreign key `invite_id ->
  session_invites.id ON DELETE CASCADE`; unique index
  `session_invite_items_invite_id_uniq`.
- `session_invite_redemptions`: `id`, non-null `invite_id`, non-null `user_id`,
  non-null `book_status` and `membership_status` defaulting to `pending`,
  nullable `last_admission_ticket_id`, and non-null integer `created_at` and
  `updated_at`; cascade foreign keys to `session_invites.id` and `user.id`;
  indexes `session_invite_redemptions_invite_user_uniq`,
  `session_invite_redemptions_invite_status_idx`, and
  `session_invite_redemptions_user_status_idx`.
- `session_invite_deliveries`: `id`, non-null `invite_id`, non-null
  `recipient_email`, non-null `status` defaulting to `pending`, non-null
  `idempotency_key`, nullable `provider_message_id`, `error_code`, and
  `sent_at`, plus non-null integer `created_at` and `updated_at`; cascade
  foreign key to `session_invites.id`; indexes
  `session_invite_deliveries_invite_email_uniq`,
  `session_invite_deliveries_invite_status_idx`, and
  `session_invite_deliveries_idempotency_key_uniq`.

## Durable Object schema and binding contracts

- Primary `USER_USAGE_LEDGER -> UserUsageLedger`, migration tag `v1`, and its
  SQLite tables `trial_ledger`, `reservations`, `voice_session`, and
  `current_allowance_period` — `UNCHANGED_VERIFIED`.
- Sharing `SESSION_ROOM -> SessionRoom`, migration tag `v1` —
  `UNCHANGED_VERIFIED`.
- New `APPLE_SESSION_ROOM -> AppleSessionRoom` and its append-only Wrangler
  migration tag — `COMPATIBLE_DELTA`; it must not rename, repurpose, or route
  `/v1` traffic through `SESSION_ROOM`.

## Other binding/configuration contracts

- Primary bindings `CF_VERSION_METADATA`, D1 `DB`, R2 `APPLE`,
  `BOOK_STORAGE`, `TTS_CACHE`, and `apple_dev`, plus KV
  `RISHI_DESKTOP_STATE` and `RATE_LIMIT_KV` — `UNCHANGED_VERIFIED`.
- Primary service binding `SHARING_WORKER -> rishi-sharing-worker`, variable
  `SHARING_WORKER_WS_URL=wss://sharing.fidexa.org`, and required secret
  `SHARING_INTERNAL_SECRET` — `COMPATIBLE_DELTA`. The sharing Worker must be
  deployed and healthy before session creation is enabled, and the internal
  secret must match the sharing Worker's `WORKER_HMAC_SECRET`.
- Primary D1 migration pattern at `origin/main` names root SQL plus the four
  historical nested migrations through
  `20260813110000_pregenerated_share_links/migration.sql` —
  `UNCHANGED_VERIFIED` as the released baseline. The current feature config
  additionally names both `20260820...` session-invite migration files — an
  **unsafe `COMPATIBLE_DELTA` pending W1**, because production already records
  both as applied while a fresh repository/database still needs a canonical
  generated chain. W1 must remove the two historical files from the deployable
  pattern, preserve them only as hashed evidence, and produce the generated
  canonical no-op proof. Neither historical file may be replayed.
- Sharing production `AUTH_BASE_URL=https://rishi.fidexa.org`, observability,
  and out-of-band `WORKER_HMAC_SECRET` — `UNCHANGED_VERIFIED`.
- Sharing custom-domain route `sharing.fidexa.org`, TURN secrets `TURN_KEY_ID`
  and `TURN_API_TOKEN`, and the production copies of the Apple DO binding and
  migration tag — `COMPATIBLE_DELTA`. DNS/custom-domain readiness and both TURN
  secrets are rollout prerequisites; `/v1` remains available on the same
  Worker.

## Production migration evidence

- `wrangler d1 migrations list rishi --remote`: **No migrations to apply**.
- `d1_migrations` rows 1–17 exist. Rows 16 and 17 are respectively:
  - `20260820112725_session_invites_from_prod_session_only/migration.sql`,
    applied `2026-08-20 11:36:33`.
  - `20260820121338_session_invites_idempotency/migration.sql`, applied
    `2026-08-20 13:04:20`.
- Historical artifact SHA-256 values:
  - first SQL: `19d6201be949a9b6811c2f629bfe96ddb0c264b29f4cbcd970a526658d5c7bb0`
  - first snapshot: `ae26961a3032d04b1a18468c1cda2ad20d26cab3507814556360904dcada4a6a`
  - second SQL: `c5b91174c89eb0fad4aa837935574d59be3e84e3bb7b259d421ae93b0c6535ac`
  - second snapshot: `05cc2d7f25b554238f5231d83139bbf4ffb671ccbb52b7919c9224950be81212`
- Every D1 query reported `changes: 0`, `rows_written: 0`, and
  `changed_db: false`.
- Physical counts: `session_invites=22`, `session_invite_items=22`,
  `session_invite_redemptions=24`, and `session_invite_deliveries=0`;
  `session_invites` has `null_keys=0` and `duplicate_pairs=0`.
- The child-table DDL, all seven explicit child-table indexes, and the counts
  above were queried directly after the first review. Those queries also
  reported `changes: 0`, `rows_written: 0`, and `changed_db: false`.

## Decision and deployment boundary

Selected path: `physical-reconciliation`. The production physical schema and
data already match the final target, but repository migration metadata does not
yet provide the required generated canonical no-op proof. `deploymentAllowed`
therefore remains `false`. Do not apply migrations, force-mark them applied,
edit generated SQL/snapshots, or deploy either Worker until W1–W5 and the final
compatibility review pass.
