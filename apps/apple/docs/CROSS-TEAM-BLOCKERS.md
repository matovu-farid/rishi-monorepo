# Cross-Team Blockers — Rishi for Apple (v1.0)

**Owner:** matovu90@gmail.com
**Audience:** anyone running the release pipeline (`docs/RELEASE.md`).
**Last updated:** 2026-06-10 (Phase 12 plan 12-06 close).

This document tracks the **worker-side** dependencies that are not in the iOS
team's control but gate parts of the v1.0 release flow. Each entry lists the
iOS-side status, the worker-side status, a verification command, and the
fallback the iOS app already implements when the dependency is missing — so
v1.0 ships regardless.

For the original ticket text see:
`.planning/phases/00-bootstrap-spikes/CROSS-TEAM/WORKER-TICKETS.md`
`.planning/phases/00-bootstrap-spikes/CROSS-TEAM/READER-APP-ENTITLEMENT.md`

---

## 1. Worker Ticket 2 — AASA hosting at `rishi.fidexa.org`

**Summary:** Worker must serve a static JSON document at
`https://rishi.fidexa.org/.well-known/apple-app-site-association` with
`Content-Type: application/json` and **no redirects** (Apple's on-device
validator does not follow redirects).

**Owner:** matovu90@gmail.com (worker side).
**iOS status:** DONE. Plan 12-03 ships `applinks:rishi.fidexa.org` in
entitlements, the in-app deep-link router, and `AASASchemaTests.swift` that
validates the JSON shape the worker must serve.
**Worker status:** OPEN.

**Verification once the worker deploys:**
```bash
curl -i https://rishi.fidexa.org/.well-known/apple-app-site-association
# Must return: HTTP/1.1 200, Content-Type: application/json, body matches
# the WORKER-TICKETS.md Ticket 2 schema.

# Then confirm Apple's CDN has picked it up:
curl -i https://app-site-association.cdn-apple.com/a/v1/rishi.fidexa.org
```

**Fallback if not live by submission:** iOS app uses the `rishi://` custom URL
scheme path (plan 12-03 router). Universal Links from rishi.fidexa.org URLs
fall back to opening in Safari. v1.0 ships.

**DIST-01 E2E sign-off blocked on:** this ticket. Marking DIST-01 "shipped
pending worker AASA" in `.planning/REQUIREMENTS.md` is acceptable for v1.0
submission.

---

## 2. Reader App Entitlement — `com.apple.developer.storekit.external-link.account`

**Summary:** Apple's External Link Account Entitlement application is the
legal vehicle for Phase 11's "Manage Subscription" external link to
Stripe's billing portal. Applied for in Phase 0 BOOT-07.

**Owner:** matovu90@gmail.com (applicant — Apple reviews).
**iOS status:** DONE. Phase 11 ships both branches — tappable button if the
entitlement is granted, text-only "manage at rishi.fidexa.org" copy if not.
The branch is decided at build-time by entitlement presence in
`rishi.entitlements`.
**Apple status:** PENDING. Application submitted 2026-05-21; typical Apple
review time 1–2 weeks.

**Verification:**
- Open https://developer.apple.com → Account → Identifiers → org.fidexa.rishi
  → Capabilities. Look for "External Link Account" capability.
- If granted: add the capability to `rishi/rishi/rishi.entitlements` for the
  App Store / MAS configurations, then rebuild — tappable UI ships.

**Fallback if not granted by submission:** ship the text-only branch. v1.0
ships. App Store Guideline 3.1.1 anti-steering rules are satisfied because
there's no tappable URL, no pricing, no CTA-styled copy.

**DIST-04 (TestFlight)** does NOT depend on this entitlement.
**DIST-05 (Mac App Store submission)** depends on the decision the runbook
captures in § 6.

---

## 3. Worker Ticket 1 — SIWA token verify + revoke endpoint

**Summary:** Worker must implement `POST /api/auth/apple/token` (verify
Apple identity token, exchange auth code for refresh token, mint Better Auth
session) and modify `POST /api/auth/delete-user` to call
`https://appleid.apple.com/auth/revoke` BEFORE row deletion.

**Owner:** matovu90@gmail.com (worker side).
**iOS status:** DONE. Phase 3 ships SIWA against the contract from
WORKER-TICKETS.md Ticket 1. Tests pass against the documented response shape.
**Worker status:** assumed DONE in production (Phase 3 has been "Complete"
in `.planning/STATE.md` since the Phase 3 close). Re-verify before App
Review — Guideline 5.1.1(v) tests account deletion path.

**Verification:**
```bash
# Sign in with Apple from the iOS app against api.fidexa.org, then immediately
# delete the account. Re-sign-in should produce a clean state (no rows for
# the deleted user). If Apple test devices see "Account already exists" on
# second sign-in, revocation is not landing — App Store will reject.
```

**Fallback:** none — this is App-Review-required. If revocation is not in
production by submission, hold the submission.

---

## 4. Worker Ticket 3 — Silent-push APNs emit on sync change

**Summary:** Worker must register device tokens (`POST /api/devices/register`)
and emit silent pushes (`{"aps":{"content-available":1}, ...}`,
`apns-priority: 5`, `apns-push-type: background`) on any write the iOS app
needs to know about. Originator must be suppressed; per-device rate limit
30s; emit to all OTHER device tokens for the same user.

**Owner:** matovu90@gmail.com (worker side).
**iOS status:** DONE. Phase 7 plan 07-04 ships device-token registration,
silent-push handler, and sync wake. Tests pass.
**Worker status:** OPEN — confirm in production before claiming SYNC-06 in
v1.0 release notes.

**Verification once worker deploys:**
- Add a book on Mac, observe iPhone wakes within 5s and the book appears.
- Logs in the worker should show one APNs send per "other" device, with
  `apns-priority: 5` and `apns-topic: org.fidexa.rishi`.

**Fallback if not live:** sync degrades to manual-refresh + foreground-only
poll. v1.0 still ships — silent push is an enhancement, not a correctness
requirement. SYNC-06 stays "shipped, pending worker emit" in REQUIREMENTS.md.

---

## 5. Phase 0 Spike A / B / C — PROVISIONAL → FINAL conversions

**Summary:** Phase 0 produced three spike reports
(`SPIKE-A-REPORT.md`, `SPIKE-B-REPORT.md`, `SPIKE-C-REPORT.md`) whose
PROVISIONAL conclusions need to be re-confirmed against shipped behavior
before v1.0 GA.

**Owner:** iOS team (matovu90@gmail.com).
**Status:** spike conclusions referenced throughout Phases 4–11; ad-hoc
verification has happened in each plan's SUMMARY. Final pass before App
Store submission: re-read each report, mark each "PROVISIONAL: ..." line as
FINAL or call out a regression.

**Fallback:** none required — this is bookkeeping. Spikes that turned out
wrong would have already broken downstream tests.

---

## Summary table

| # | Blocker | iOS side | Worker side | Gates |
|---|---------|----------|-------------|-------|
| 1 | AASA at rishi.fidexa.org | DONE (plan 12-03) | OPEN | DIST-01 E2E |
| 2 | Reader App entitlement | DONE (both branches in 11-x) | PENDING Apple | DIST-05 decision |
| 3 | SIWA verify + revoke | DONE (Phase 3) | assumed DONE | App Review 5.1.1(v) |
| 4 | Silent-push APNs emit | DONE (07-04) | OPEN | SYNC-06 claim in notes |
| 5 | Spike A/B/C finalization | bookkeeping | n/a | Pre-submission audit |
