# Session Sharing Effect Adoption — Design Draft

> **Status:** User-approved for planning; independent adversarial review passed (5 rounds, 0 open Critical/High/Medium).

## Goal

Use Effect as the primary composition model for backend shared-reading operations across `rishi-worker` and `rishi-sharing-worker`, improving typed failures, dependency boundaries, cleanup behavior, and diagnostics without changing existing client-visible contracts.

## Current state and problem

- `workers/worker` already depends on Effect, but `src/routes/session-shares.ts` and `src/session-sharing-service.ts` implement shared-reading workflows as Promise chains, repeated `try/catch`, and thrown `SessionSharingServiceError` values.
- Some failures lose meaning: malformed JSON can become a default body; room status probes can turn infrastructure failures into `null`; create-room compensation errors are discarded; HTTP response parsing can lose correlation metadata.
- `workers/sharing-worker` does not depend on Effect. Its Hono routes, auth and TURN helpers, and `AppleSessionRoom` command workflows use Promise-based error handling and can collapse unexpected failures to generic response codes.
- Existing code and prior changes in these files are user-owned and dirty. Implementation must preserve those edits and incorporate them rather than replace or revert them.

## Approaches considered

1. **Effect wrappers at Promise boundaries.** Small diff, but leaves the domain workflows and dependency graph Promise-based; rejected because the request is to capitalize on Effect beyond error handling.
2. **Convert every helper and runtime operation to Effect.** Broad conversion adds ceremony to pure logic and Cloudflare primitives without improving the operation boundaries; rejected as indiscriminate.
3. **Effect-first sharing workflows with explicit runtime adapters (recommended).** Use composable typed Effects and Effect services/layers for the shared-reading use cases and their external dependencies, then run/translate results exactly at Hono, Durable Object RPC, and WebSocket boundaries. Keep pure validation/transforms synchronous where they do not benefit from Effect.

## Design

### Effect boundary and services

- Add Effect v3 to the `workers/sharing-worker` package, matching the version already used by `workers/worker` (`^3.21.4`); update `workers/sharing-worker/pnpm-lock.yaml` with that package's pnpm workflow. `workers/worker` is governed by the repository's Bun instructions and its existing Bun lockfile.
- Define small `Context.Tag` services for sharing-specific dependencies (internal Worker fetch/signing, database operations where shared-reading routes use D1, room commands, auth identity lookup, TURN credential provider, Resend invite delivery, and structured diagnostics). Bind concrete Cloudflare environment/resources in request or Durable Object execution layers; do not store request-specific state in module globals.
- Keep the Effects at use-case level: authenticated profile/context lookup; create/idempotently reconcile/compensate room; redeem; email invitations; active/session status; book-ready/rejoin admission; TURN credentials; start/end/leave; controller transfer; participant remove/restore; room observations; auth; WebSocket admission/control; and account-reference revocation/purge. Helpers should return Effects when they perform fallible I/O or participate in typed workflows; pure mapping/validation remains plain code.
- Invite email delivery remains a per-recipient, idempotent batch with partial success. Preserve the current `{ attempted, sent, failed, results }` result and `sent` / `already_sent` / `failed` statuses, along with persisted safe `errorCode`; provider details and credentials stay out of client responses and logs.

### Typed failure model

- Use a sharing-specific tagged failure taxonomy that distinguishes expected domain failures (for example `SESSION_NOT_FOUND`, `SESSION_ENDED`, `ROOM_FULL`, stale controller generation, book hash mismatch, and authorization rejection) from dependency/transport/parse failures and unexpected defects.
- Preserve safe public `code`, `status`, retryability/action hints, stage, and correlation ID. Retain the original cause internally for structured logs; do not serialize raw causes, provider bodies, bearer tokens, invite tokens, or stacks to clients.
- A multi-step create/compensate failure must retain both the primary operation failure and cleanup failure in the Cause/log context while returning the established safe public response.
- Do not use broad fallbacks such as `.catch(() => null)` for infrastructure failures. A genuine absent room remains distinct from failed status lookup.

### Worker boundaries and compatibility

- Refactor the primary Worker service and share-route orchestration into Effects; compose route use-cases from the service Effects rather than repeating endpoint-level try/catch.
- Refactor the sharing Worker's auth, TURN, Apple room internal-command, admission, and relevant WSS route workflows into Effects. `auth.ts` is also used by legacy `/v1` helpers, so retain a Promise compatibility runner for those handlers without changing their behavior. `AppleSessionRoom.webSocketMessage` dispatches both Apple and legacy socket protocols; convert only the Apple-specific branch and leave legacy `SessionRoom` semantics intact.
- Hono/DO/WS handlers are the only Promise/Response conversion boundaries. Map typed failures once into the current JSON fields, HTTP statuses, response headers, DO RPC result values, and WebSocket frames/close behavior. Preserve current public error codes and successful payload shapes for older clients.
- For Durable Object RPC, log the full safe Cause summary and correlation ID before returning the serializable failure envelope; never rely on exception stacks surviving the RPC hop.
- Keep the distinct existing internal contracts distinct: the `executeInternal` Durable Object result uses `{ ok: false, code, error }` for expected command failure; the sharing Worker's internal HTTP endpoint uses `{ code, error }` for request/gateway failure and may wrap DO failures in its own `{ ok: false, code, error }`; account-reference revocation's successful not-found outcome remains `{ ok: true, status: "not_found" }`.
- WebSocket callbacks run after the HTTP upgrade and cannot map errors to HTTP responses. Preserve current protocol error-frame codes/messages and close codes/reasons for `webSocketMessage` and upgrade/admission paths; use correlated Cause logging for unexpected callback defects rather than changing the established frame/close behavior. Apply the same logging discipline to lifecycle callbacks such as close/error/alarm where an Effect failure is caught at that boundary.
- Preserve existing request correlation IDs from API through the sharing Worker and room command logs. Emit structured logs with operation, stage, outcome, safe code, duration, and correlation ID.

## Scope

In scope:

- `workers/worker/src/routes/session-shares.ts`
- `workers/worker/src/session-sharing-service.ts` and focused new sharing service/use-case modules if extraction is needed
- `workers/worker/src/session-invite-email.ts` so Resend sending and invite status persistence compose with the route's Effect workflow
- The two `SessionSharingService` callers in `workers/worker/src/account-deletion.ts` only as a narrow compatibility adapter: keep its existing Promise/Error behavior for that unrelated deletion workflow while the sharing route path uses the new Effect API. Do not otherwise refactor account deletion.
- `workers/sharing-worker/src/index.ts`, `auth.ts`, `turn.ts`, and `AppleSessionRoom.ts` plus focused new Effect error/service modules
- `workers/sharing-worker/package.json` and `workers/sharing-worker/pnpm-lock.yaml`
- Applicable type/build checks and an explicit compatibility inventory for changed boundaries; no automated cross-device E2E requirement (manual shared-reading verification remains with the user).

Out of scope:

- Unrelated API Worker and Durable Object domains
- Client/UI behavior or changes to the sharing wire protocol
- Database schema or migration changes unless implementation discovers a proven requirement; any such discovery requires a separate reviewed design because this refactor is not intended to change persistence.
- Automatic production deployment before implementation review, compatibility checks, and type/build verification pass.

## Rollout and verification

- Implement in ordered slices: (1) typed contracts and primary Worker client/use-cases, (2) Hono share routes, (3) sharing Worker auth/TURN and room workflows, (4) boundary/error contract audit and cleanup.
- Preserve dirty user changes; inspect the full current diff before each slice and deploy only after verifying exactly what source would be included.
- Run the two Worker type checks and available production build/bundle checks. User requested implementation focus rather than tests/E2E; do not gate on automated cross-device E2E. During review, compare the changed mappings against an inventory of existing HTTP codes/statuses/envelopes and WebSocket error frames/close reasons so compatibility is checked without expanding into end-to-end feature automation.
- Deploy both Workers only after the user-approved spec/plan is implemented and reviewed, with no database migration unless separately reviewed. Smoke-check health and representative non-secret error envelopes; report exact release IDs and check limits. The user will manually verify cross-device behavior.

## Acceptance criteria

1. Both Workers use Effect as the normal composition mechanism for fallible shared-reading workflows, not merely at catch/response boundaries.
2. Expected domain and dependency failures are represented in typed failure channels; causes remain available for safe correlated internal diagnostics.
3. Absent state is distinguishable from dependency outage, and compensation failure is observable without masking the primary failure.
4. Existing successful payloads, public stable error codes/statuses, each internal HTTP/DO envelope, and WebSocket error-frame/close behavior remain compatible.
5. The account-deletion caller retains its current Promise/Error contract without requiring a broad deletion-flow refactor.
6. Both Workers pass their applicable type/build checks and are redeployed after reviewed implementation; deployment and smoke-check evidence is recorded.

## Adversarial review loop

### Research review — Round 1

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Durable Object RPC strips exception stacks, so typed errors alone cannot preserve diagnostics across the RPC hop. | Log a safe Cause summary with correlation ID at the DO boundary before returning the serializable error envelope. |
| 2 | High | A `null` status fallback can conflate a missing room with an unavailable Worker. | Model `NotFound` separately from dependency failure; remove broad null fallbacks in affected workflows. |
| 3 | Medium | Existing response shape and deployed clients constrain error mapping. | Keep the current public and internal envelopes stable; translate typed failures only at runtime boundaries. |

**Round 1 result:** Design updated; independent re-review required before implementation planning.

### Research review — Round 2

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `SessionSharingService` also has an account-deletion caller relying on Promise rejection and `SessionSharingServiceError.code`. | Keep a narrow Promise/Error compatibility facade for the account-deletion call site while route workflows use Effects; do not refactor unrelated deletion behavior. |
| 2 | High | Post-upgrade WebSocket callbacks return frames/close behavior, not HTTP responses. | Explicitly preserve current protocol error frames and close codes/reasons; log unexpected Effect causes at callbacks with correlation context. |
| 3 | Medium | Internal DO result, internal HTTP failure, and revocation not-found success envelopes differ. | Specify each envelope separately and keep its existing shape. |

**Round 2 result:** Draft updated with concrete compatibility and socket-boundary requirements; independent re-review required.

### Research review — Round 3

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | `auth.ts` also backs legacy `/v1` routes. | Keep a Promise compatibility runner for those legacy callers while the sharing workflows use Effects. |
| 2 | Medium | One Apple Durable Object dispatches both Apple and legacy socket protocols. | Convert only the Apple-specific WebSocket branch; preserve the legacy branch and `SessionRoom` behavior. |
| 3 | Medium | Broad response and WebSocket compatibility criteria need concrete verification evidence. | Require an inventory comparison of existing response codes/statuses/envelopes and WebSocket error frames/close reasons during review; no cross-device E2E automation. |

**Round 3 result:** Medium findings incorporated as implementation constraints; independent re-review required.

### Research review — Round 4

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The route inventory includes Resend-backed email invitations and the authenticated share context endpoint, which were not individually named as use cases/modules. | Enumerate share context and invitation workflows explicitly and add `session-invite-email.ts` to scope. |

**Round 4 result:** Scope inventory expanded; independent re-review required.

### Research review — Round 5

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The email use case performs external Resend delivery, but the adapter list did not identify the provider and its partial-success/idempotency contract. | Add a `Resend invite delivery` Effect service and explicitly preserve per-recipient idempotency, partial-success result shape/statuses, and safe persisted error codes. |

**Round 5 result:** PASS — 0 open Critical, High, or Medium issues. Resend boundary and batch compatibility are explicit; only low implementation cautions remain: preserve legacy WebSocket dispatch and compare exact existing response/frame mappings during review.
