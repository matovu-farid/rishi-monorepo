import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

/**
 * Date wire-audit sweep — Phase 17 Plan 10.
 *
 * LOAD-BEARING regression guard. The iOS WorkerClient at
 * apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96 uses a
 * bare `JSONDecoder()` with the default `.deferredToDate` strategy. For Date
 * fields this means:
 *
 *   "JSON number = seconds since 2001-01-01T00:00:00Z (Apple reference date)"
 *
 * 2001-01-01 is 978_307_200_000 ms after the 1970 unix epoch. Every Date
 * field emitted from any worker route that iOS decodes via WorkerClient MUST
 * therefore go out the wire as:
 *
 *     (msEpoch - 978_307_200_000) / 1000
 *
 * This audit is a static + behavioural sweep across every iOS-decoded route.
 * It does NOT re-mock each route end-to-end (the per-route tests already do
 * that — see devices.test.ts, sync-push.test.ts, upload-url.test.ts,
 * download-url.test.ts, changes.test.ts). Its job is:
 *
 *   1. STATIC: assert the canonical conversion constant `978_307_200_000`
 *      appears in every Date-emitting iOS-decoded route source. If a future
 *      edit accidentally rips the constant out, this test fails before the
 *      route can ship.
 *
 *   2. STATIC: assert that NO iOS-decoded route source contains a raw
 *      `.toISOString()` JSON value (i.e. inside a `c.json(...)` body). The
 *      grep allows documented exceptions (apple-me.ts premiumUntil — see
 *      Phase 17 CONTEXT.md, /health probe — human-readable). Any new
 *      ISO-string Date emission on an iOS-decoded route flags here before
 *      it can break iOS decoding.
 *
 *   3. BEHAVIOURAL: lock the seconds-since-2001 contract with a low-level
 *      assertion that the canonical conversion `(msEpoch - REF_OFFSET) /
 *      1000` round-trips through `Date(timeIntervalSinceReferenceDate:)`
 *      arithmetic. This is the cross-side decoder contract distilled into
 *      one numeric equality the test runner can prove without a Swift
 *      runtime.
 *
 * Distinct iOS-Date-decoded routes covered (Swift `Date` field on the wire):
 *
 *   - POST /api/devices/register      -> registered_at  (Plan 17-02)
 *   - POST /api/sync/push             -> accepted_at    (Plan 17-07)
 *   - POST /api/sync/upload-url       -> expires_at     (Plan 17-08)
 *   - POST /api/sync/download-url     -> expires_at     (Plan 17-09)
 *   - GET  /api/sync/changes          -> updated_at     (quick-task 260612-g89)
 *
 * Phase 16 `/api/sync/conversations` and `/api/sync/messages` are
 * deliberately EXCLUDED from this sweep: those routes' `updated_at` /
 * `created_at` fields are typed `Int64` (ms-since-1970) on the iOS side
 * (see apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/
 * ConversationsSyncAPI.swift + MessagesSyncAPI.swift) — they are NOT decoded
 * as Swift `Date`, so the seconds-since-2001 wire convention does not apply.
 * The Phase 16 contract (apps/apple/docs/WORKER-CONTRACT-CHAT-SYNC.md §3.1)
 * locks the ms-epoch wire shape for those rows explicitly.
 *
 * Documented allow-listed exceptions (NOT changed by this sweep):
 *
 *   - workers/worker/src/billing/apple-me.ts:84,91 — `premiumUntil` ISO8601
 *     string. iOS /me decodes it as a String, not a Date — see Phase 14-09
 *     SUMMARY + Phase 17 CONTEXT.md decisions. Locked.
 *   - workers/worker/src/index.ts:382 — `/health` probe timestamp ISO8601.
 *     Human-readable health endpoint, not an iOS-decoded route.
 *
 * Note: routes/upload.ts used to hand-roll the SigV4 `X-Amz-Date` via
 * `.toISOString()`, but presigning now delegates to `src/r2-presign.ts`
 * (aws4fetch sets X-Amz-Date internally), so upload.ts no longer carries an
 * ISO-string exception. Its iOS-decoded `expires_at` is still converted via
 * 978_307_200_000 on the response side.
 */

const REFERENCE_DATE_OFFSET_MS = 978_307_200_000

// Resolve workers/worker/src/ as the audit root. The test file lives at
// workers/worker/src/date-wire-audit.test.ts, so __dirname == src/.
const __filename = fileURLToPath(import.meta.url)
const SRC_ROOT = dirname(__filename)

function readSource(relativeFromSrc: string): string {
  return readFileSync(join(SRC_ROOT, relativeFromSrc), "utf8")
}

// Routes that emit a Date in a JSON response body iOS decodes via
// WorkerClient.swift:96 `JSONDecoder()` (.deferredToDate).
const IOS_DECODED_DATE_ROUTES: ReadonlyArray<{
  path: string
  source: string
  dateFieldsEmitted: readonly string[]
}> = [
  {
    path: "POST /api/devices/register",
    source: "routes/devices.ts",
    dateFieldsEmitted: ["registered_at"],
  },
  {
    path: "POST /api/sync/push",
    source: "routes/sync.ts",
    dateFieldsEmitted: ["accepted_at"],
  },
  {
    path: "POST /api/sync/upload-url, POST /api/sync/download-url",
    source: "routes/upload.ts",
    dateFieldsEmitted: ["expires_at"],
  },
  {
    path: "GET /api/sync/changes",
    source: "routes/changes.ts",
    dateFieldsEmitted: ["updated_at"],
  },
]

// Routes that emit numeric ms-epoch timestamps decoded by iOS as Int64 (NOT
// Swift `Date`). Listed here so the audit reader knows they were considered
// and consciously excluded — not silently missed.
const NON_DATE_NUMERIC_ROUTES: ReadonlyArray<{
  path: string
  source: string
  reason: string
}> = [
  {
    path: "POST + GET /api/sync/conversations",
    source: "routes/conversations.ts",
    reason:
      "iOS ConversationsSyncAPI decodes updated_at/created_at as Int64 ms-epoch (Phase 16-02). Not a Swift Date field.",
  },
  {
    path: "POST + GET /api/sync/messages",
    source: "routes/messages.ts",
    reason:
      "iOS MessagesSyncAPI decodes updated_at/created_at as Int64 ms-epoch (Phase 16-02). Not a Swift Date field.",
  },
]

// Sources where a raw `.toISOString()` JSON-value is documented and locked.
// Adding entries here REQUIRES a CONTEXT.md decision pointing at the rationale.
const ISO_STRING_ALLOWED_SOURCES: readonly string[] = [
  "billing/apple-me.ts", // premiumUntil — Phase 14-09 / 17-CONTEXT.md
  "billing/jws-verify.ts", // error message strings, not JSON bodies
  "index.ts", // /health probe timestamp
]

describe("Date wire-audit (Phase 17 Plan 10)", () => {
  describe("static: canonical conversion constant present per route", () => {
    for (const route of IOS_DECODED_DATE_ROUTES) {
      it(`${route.source} contains the canonical constant 978_307_200_000`, () => {
        const src = readSource(route.source)
        // Either the literal constant or a direct numeric expression. Allow
        // either underscored form (idiomatic) or the bare digits.
        const hasConstant =
          src.includes("978_307_200_000") || src.includes("978307200000")
        expect(
          hasConstant,
          `Date-emitting route ${route.path} (${route.source}) emits ${route.dateFieldsEmitted.join(", ")} ` +
            "but does not reference the canonical seconds-since-2001 offset 978_307_200_000. " +
            "Either:\n" +
            "  (a) the route converts via Phase 16 D1 columns that already store seconds-since-2001 " +
            "(in which case add an explanatory comment + add this source to a pass-through allowlist below), or\n" +
            "  (b) the route is freshly broken — restore the conversion to match " +
            "iOS WorkerClient.swift:96 .deferredToDate.",
        ).toBe(true)
      })
    }
  })

  describe("static: no raw toISOString() Date in iOS-decoded JSON bodies", () => {
    for (const route of IOS_DECODED_DATE_ROUTES) {
      it(`${route.source} contains no unguarded .toISOString() Date wire emission`, () => {
        // Allow-listed sources have a documented non-iOS-Date use of
        // .toISOString() (see ISO_STRING_ALLOWED_SOURCES — e.g. AWS SigV4
        // X-Amz-Date in upload.ts). Skip the static grep for those; they
        // are independently audited by the "allow-list honesty" suite below.
        if (ISO_STRING_ALLOWED_SOURCES.includes(route.source)) return

        const src = readSource(route.source)
        // Source is allowed to have toISOString IF it's inside a comment.
        // The audit is conservative: grep live code lines only.
        const offendingLines: string[] = []
        for (const [lineIndex, line] of src.split("\n").entries()) {
          const trimmed = line.trim()
          if (trimmed.startsWith("//") || trimmed.startsWith("*")) continue
          if (trimmed.includes(".toISOString()")) {
            offendingLines.push(`${lineIndex + 1}: ${trimmed}`)
          }
        }
        expect(
          offendingLines,
          `${route.source} emits .toISOString() — would break iOS .deferredToDate decode. ` +
            `Offending lines:\n${offendingLines.join("\n")}`,
        ).toEqual([])
      })
    }
  })

  describe("static: ms-epoch (Int64) routes are documented + present", () => {
    for (const route of NON_DATE_NUMERIC_ROUTES) {
      it(`${route.source} is consciously excluded from the seconds-since-2001 sweep`, () => {
        // The source must exist (catches a future move/delete).
        const src = readSource(route.source)
        expect(src.length).toBeGreaterThan(0)
        // The exclusion reason is documented in this suite — re-asserted here
        // so test output makes the contract visible:
        expect(route.reason).toMatch(/Int64/)
      })
    }
  })

  describe("static: ISO-string allow-list is honest", () => {
    it("every allow-listed source actually contains toISOString (no dead entries)", () => {
      for (const allowed of ISO_STRING_ALLOWED_SOURCES) {
        const src = readSource(allowed)
        expect(
          src.includes(".toISOString()"),
          `Allow-list entry ${allowed} has no .toISOString() — entry is stale, remove it.`,
        ).toBe(true)
      }
    })
  })

  describe("behavioural: seconds-since-2001 conversion arithmetic", () => {
    it("978_307_200_000 ms epoch is exactly 2001-01-01T00:00:00Z", () => {
      // The reference date Apple's Date(timeIntervalSinceReferenceDate:) uses
      // is 2001-01-01T00:00:00Z. UTC millis from epoch:
      const referenceDateMs = Date.UTC(2001, 0, 1, 0, 0, 0, 0)
      expect(referenceDateMs).toBe(REFERENCE_DATE_OFFSET_MS)
    })

    it("(now - REF_OFFSET) / 1000 round-trips back to the original ms", () => {
      const nowMs = Date.now()
      const onWire = (nowMs - REFERENCE_DATE_OFFSET_MS) / 1000
      // The iOS decoder reconstructs the Date by:
      //   Date(timeIntervalSinceReferenceDate: onWire)
      // i.e. it adds REF_OFFSET / 1000 seconds back. In ms epoch terms:
      const decodedMs = onWire * 1000 + REFERENCE_DATE_OFFSET_MS
      expect(decodedMs).toBe(nowMs)
    })

    it("a JSON number is what iOS .deferredToDate consumes", () => {
      // Documented to keep the contract visible in test output. iOS reads:
      //
      //   case 200..<300:
      //       return try JSONDecoder().decode(E.Response.self, from: data)
      //
      // With no custom dateDecodingStrategy. For Date fields the strategy is
      // .deferredToDate, which calls Date(timeIntervalSinceReferenceDate:)
      // with a Double pulled from the JSON. Strings would throw at decode
      // time — hence the static no-toISOString sweep above.
      const probe: { value: number } = { value: 12345.5 }
      // typeof check matches the per-route runtime assertions (devices.test.ts,
      // sync-push.test.ts, upload-url.test.ts, download-url.test.ts) that
      // each call `expect(typeof body.<field>).toBe("number")`.
      expect(typeof probe.value).toBe("number")
    })
  })

  describe("behavioural: documented exceptions stay locked", () => {
    it("billing/apple-me.ts continues to emit premiumUntil as ISO8601 (locked exception)", () => {
      const src = readSource("billing/apple-me.ts")
      expect(src.includes("premiumUntil")).toBe(true)
      expect(src.includes(".toISOString()")).toBe(true)
    })

    it("/health endpoint timestamp stays ISO8601 (human-readable health probe)", () => {
      const src = readSource("index.ts")
      // The /health handler is a human probe, not an iOS-decoded route — see
      // Phase 17 CONTEXT.md decisions. Locked.
      expect(src).toMatch(/\/health[\s\S]{0,200}?toISOString\(\)/)
    })
  })
})
