# Cross-platform telemetry and error reporting

> **Status:** Implemented with follow-up diagnostics — privacy assumption explicitly recorded below; stack frames and short-lived opaque request correlation are now retained.

## Problem

Sentry currently cannot distinguish the iOS failures that are grouped as
`RishiError: rishi.error`. The iOS bridge intentionally replaces the original
error, operation, tags, extra data, and breadcrumb data with generic values.
The Worker wraps the app in Sentry, but its TTS routes catch provider and
ledger failures and return a response, so those failures never reach the
wrapper.

## Goals

- Make iOS TTS and adjacent audio lifecycle failures searchable by stable
  operation, stage, error code, release, and safe state metadata.
- Capture caught Worker TTS failures while retaining current client-facing
  response behavior.
- Keep raw errors available to local diagnostics without sending raw provider
  messages or user content to Sentry.
- Keep consent gating and existing uncommitted feature work intact.
- Add tests for allowlisting and the caught-error reporting paths before
  production changes.

## Non-goals

- Reconstructing the historical generic Sentry events.
- Enabling performance tracing, replay, network breadcrumbs, or default PII.
- Changing TTS provider behavior, retry policy, audio formats, billing, or
  user-facing error text.
- Adding a second telemetry backend or changing the web UI's existing Sentry
  setup.

## Privacy contract

The implementation assumes the user wants only an allowlisted diagnostic
contract. Sentry may receive feature, operation, stage, stable error code/type,
HTTP status, provider enum, release, response mode, cache outcome, request-size
counts, bounded numeric lifecycle state such as an audio generation,
short-lived opaque TTS correlation IDs, and bounded lifecycle timings/counts. It
must not receive narration text, book or chat content, audio bytes or URLs,
request bodies, provider response bodies, auth/session/user identifiers, raw
error descriptions, or arbitrary caller-provided fields. Correlation IDs are
per-playback random UUIDs, are not user/session identifiers, and are used only
to join one iOS request to its Worker stream.

## Chosen approach

### iOS

Extend the existing `Log` → `SentryBridge` seam with an internal
`DiagnosticPayload` whose fields are fixed to `feature`, `operation`, `stage`,
`errorCode`, `provider`, `httpStatus`, `responseMode`, `cacheResult`,
`requestChars`, and `audioGeneration`. `Log.error` remains source-compatible
and gains optional operation/payload arguments. `SentryBridge.capture` creates
a newly constructed sanitized `NSError` and adds only approved tags/context;
the original error is passed only so the SDK can attach native stack frames.
The `beforeSend` filter replaces its message/type and removes automatic
payloads. Breadcrumbs retain only the safe event name and approved fields.

The `beforeSend` filter remains the final privacy boundary: it keeps only the
same fixed tags/context and drops all other tags, extras, user, request,
raw error details, and arbitrary breadcrumb data while retaining symbolicated
exception frames. Existing local
`os.Logger` and simulator sinks keep the raw `Error` representation for
debugging. Tests must exercise this final event-filtering seam, not only the
pure sanitizer.

Update TTS parser, streamer, engine, player, and audio-session failure sites to
use stable operation/stage/error-code values. Avoid content and free-form
provider messages even when they appear in existing event data. TTS stream IDs
are validated opaque correlation UUIDs, not user or session identifiers.

### Worker

Add a small best-effort reporting helper around the existing
`@sentry/cloudflare` API. It uses an isolation scope, sets only the same
allowlisted tags/context, and calls `captureException` with a sanitized error.
The TTS route calls it in caught provider, reservation, and stream setup
failures before returning the existing generic status/body. Expected client
validation failures remain unreported; operational/provider failures are
reported with stable codes and status.

The pinned SDK exposes `withIsolationScope` and `captureException`. The helper
uses the active request scope when present, but is safe when asynchronous
`waitUntil` work has lost the request scope. The existing `sendDefaultPii:
false` option is not treated as an allowlist: upstream response bodies must no
longer be logged, and the Sentry `beforeSend` option must scrub request data
and console-derived breadcrumbs if the Worker config exposes that hook.

The reporter is called only from authenticated TTS routes after
`requireAiDataConsent`; the Worker has no separate end-user telemetry toggle
in this change. iOS continues to use its existing explicit Sentry consent
gate. This distinction is documented and tested at the route boundary.

### Other surfaces

Do not broaden this change into a new sharing-worker Sentry integration. The
sharing worker's existing Cloudflare observability and the web app's existing
Sentry setup remain unchanged unless a directly shared helper or test requires
an additive naming update.

## Alternatives considered

1. **Only improve breadcrumbs.** Smallest diff, but captured exceptions would
   still be grouped generically and caught Worker failures would remain
   invisible. Rejected.
2. **Forward raw errors/messages and request context.** Fastest to implement,
   but violates the app's content/privacy boundary and creates unstable,
   high-cardinality Sentry data. Rejected.
3. **Introduce a new cross-platform telemetry service.** Gives a unified API,
   but expands scope and creates a second integration while the existing
   bridges are already the consent and SDK boundaries. Rejected for this
   iteration.

## Verification

- iOS unit tests prove safe fields survive, forbidden fields are removed, and
  raw error text is not used for Sentry grouping.
- Worker tests prove caught TTS failures call the reporter with bounded data,
  while response status/body remain unchanged and expected 4xx validation is
  not reported.
- Run focused iOS logging/audio tests and Worker Bun tests/type checks.
- Review the final diff against the pre-existing dirty worktree and confirm
  no unrelated files were reverted.

## Research-stage adversarial review

### Round 1 — initial review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Generic iOS `beforeSend` filtering can accidentally continue to erase the new diagnostics. | Make the allowlist/filter part of the implementation contract and test the filter behavior directly. |
| 2 | High | Worker wrapper-only capture misses errors caught by TTS routes. | Call a best-effort reporter at each operational catch boundary and test caught-error behavior. |
| 3 | High | Free-form existing TTS event data may contain provider text. | Route Sentry data through a fixed-key/fixed-value allowlist; local sinks may retain raw values. |
| 4 | Medium | UUID correlation IDs can become identifying/high-cardinality telemetry. | Use bounded numeric lifecycle state only; omit request/session/user IDs. |
| 5 | High | Worker console integration can turn logged provider response bodies into Sentry breadcrumbs, and `sendDefaultPii: false` is not a complete request-data allowlist. | Stop logging body text and add a Worker `beforeSend` scrub/drop boundary for request/console-derived data. |
| 6 | High | Consent semantics differ between iOS Sentry and Worker AI routes. | Document iOS explicit telemetry consent and Worker authenticated-AI-consent boundary; do not imply they are the same toggle. |

**Round 1 result:** Re-review required after the allowlist API and call-site map
are finalized in the implementation plan.

### Round 2 — independent re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Worker console logging can leak upstream response bodies into breadcrumbs. | Stop logging upstream bodies and add a final Worker scrub boundary. |
| 2 | High | Post-response stream failures are outside the route catch. | Report inside the asynchronous stream read catch with stable metadata. |
| 3 | High | Consent semantics differ by surface. | Keep iOS `isLive` as the explicit telemetry gate and treat Worker authenticated AI consent as its route boundary. |

**Round 2 result:** PASS — 0 open Critical/High issues. The implementation
plan contains the concrete API, test order, and call-site audit.

### Round 3 — implementation-risk re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Raw-mode Worker streaming can fail outside the SSE transform. | Use a shared reporting wrapper for both raw and SSE response modes. |
| 2 | High | A sidecar can run after the active Sentry scope is gone. | Capture through the initialized client with an explicit scope, not only ambient scope state. |
| 3 | High | Missing ElevenLabs configuration is an operational failure outside the catch. | Report it with a stable configuration error code before returning 503. |
| 4 | High | The iOS audit must include decoder/cache/custom-engine/audio-session producers. | Add those producers to the required call-site map and tests. |

**Round 3 result:** Re-review required after the plan and red tests cover these
additional boundaries.

### Round 4 — final re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Raw and SSE streams need the same post-response failure visibility. | The Worker uses one reporting wrapper before selecting raw or SSE output. |
| 2 | High | Sidecar capture must work after request scope teardown. | The reporter uses the initialized Sentry client with an explicit scope. |
| 3 | High | Early provider configuration failures need the same diagnostic contract. | ElevenLabs missing-key failures report a stable configuration code. |
| 4 | High | The iOS producer audit needed concrete decoder/cache/player/session coverage. | Those producers now emit fixed diagnostics through the existing consent-gated bridge. |

**Round 4 result:** PASS — 0 open Critical/High issues.
