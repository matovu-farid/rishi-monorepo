# Rishi for Apple Platforms

## What This Is

Rishi for Apple — a native SwiftUI app that brings the full Rishi AI book-reader experience (EPUB/PDF library, chat-with-the-book, TTS, real-time voice, sync) to iPhone, iPad, and Mac (via Catalyst). It preserves relevant product behavior from the archived Electron predecessor while replacing every Node/native-module dependency with first-class Apple frameworks. Distributed through TestFlight → App Store and Mac App Store.

The deprecated Electron app is no longer in this monorepo. Its pinned source
is preserved in the private
[`rishi-electron-legacy`](https://github.com/matovu-farid/rishi-electron-legacy/tree/e460dda4eed5d69134d2e7f865b2d14a51de277e)
archive; references to it in the codebase maps below are historical snapshots,
not active implementation instructions.

## Core Value

A user can pick up any iPhone/iPad/Mac, open Rishi, and continue their book + the chat conversation they were having on the desktop app — without losing context, without re-uploading content, without a degraded reading or AI experience.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- **Native StoreKit 2 IAP for premium subscriptions** — Validated in Phase 13 (2026-06-11). Replaces the Phase-11 text-only paywall fallback. Two products (`org.fidexa.rishi.pro.monthly`, `org.fidexa.rishi.pro.annual`) with 7-day intro trials. Full purchase + restore + manage + Transaction.updates listener. Worker contract for `/api/billing/verify-receipt` + ASSN V2 documented. Anti-steering CI gate strict-on. Ships dark behind `StoreKitIAPFlag` until App Store Connect product setup completes.

### Active

<!-- Parity scope, sliced into capability groups. Each maps to formal REQ-IDs in REQUIREMENTS.md. -->

- [ ] **Authentication**: Sign in with Apple (primary), Google OAuth via `ASWebAuthenticationSession` (secondary), session persistence in Keychain, dev-bypass for premium gates in debug builds
- [ ] **Library**: Local catalog with covers, reading-now shelf, import via Files / share sheet / iCloud Drive, delete, search
- [ ] **EPUB reader**: Native renderer (NSAttributedString / WebKit-based), pagination, themes, font size, table of contents, bookmarks, highlights, last-position sync
- [ ] **PDF reader**: PDFKit-backed renderer, page navigation, annotations, last-position sync
- [ ] **Chat with book**: LLM chat tied to the open book, conversation history, retrieval via worker-backed embeddings (no on-device vector store in v1; cloud RAG)
- [ ] **Conversations**: List/search/delete past chats, empty-state UX
- [ ] **TTS (Read Aloud)**: Stream from `/api/audio/speech` with playback controls, lockscreen MPRemoteCommand
- [ ] **Real-time voice chat**: WebRTC realtime mode through `/api/voice-sessions`, preserving relevant behavior from the archived predecessor
- [ ] **Sync**: R2 sync via existing `/api/sync/{upload,download}-url` worker endpoints — books, positions, highlights, conversations
- [ ] **Billing**: Stripe-managed subscription, billing portal handoff (no IAP for v1 — out of scope below)
- [ ] **Onboarding**: First-run flow, permissions (notifications, mic for voice), sample book
- [ ] **Settings**: Account, theme, reader preferences, sync status, telemetry opt-in
- [ ] **Telemetry/crash**: Sentry coverage for the Apple app
- [ ] **Deep links**: `rishi://` for auth callback + share/handoff between desktop and mobile
- [ ] **Multi-form-factor**: iPhone, iPad (split view, multi-column), Mac Catalyst (sidebar, menu bar)

### Out of Scope

<!-- Explicit boundaries. Reason stated to prevent re-adding. -->

- **MOBI / AZW3 reader formats** — Niche legacy Amazon formats; EPUB + PDF cover the common case. Defer to v2.
- **Side-loaded / non-App-Store distribution** — Stay on App Store + Mac App Store. Don't fight notarization side-channels.
- **In-app purchase (IAP) for subscriptions** — v1 uses existing Stripe + billing portal handoff. Apple IAP migration is a separate phase if/when Apple enforces it.
- **On-device transformer embeddings / vector store** — Electron uses `@xenova/transformers` + `hnswlib-node`; iOS will use cloud RAG only in v1. CoreML embeddings considered v2+.
- **visionOS** — Not in v1 scope. May follow if Mac Catalyst lands cleanly.
- **Multi-window / Stage Manager polish** — Single-scene experience for v1; multi-scene support deferred.

## Context

**Historical parity reference:** Electron v1.4.0 is preserved at the pinned private archive above. The codebase maps under `.planning/codebase/` capture that historical implementation for product-behavior context; current implementation decisions belong to the Apple app and current Worker contracts.

**Worker backend:** The primary Worker at `api.fidexa.org` serves the Apple app's current API surface, including `/api/voice-sessions`. Legacy `/desktop/*` contracts remain for released-client compatibility. The sharing Worker on `origin/main` exposes only frozen legacy `/v1`; Apple `/v2` sharing is planned and must be implemented separately before shared-reading acceptance testing.

**Current Apple project:** `apps/apple/rishi/` contains the active Xcode project, application sources, unit tests, and UI tests.

**Sibling apps in monorepo:** `apps/web`. The deprecated Electron app is an external, read-only archive and must not be treated as an active sibling or build target.

**Native-module replacements (from STACK.md):**
| Electron | iOS native equivalent |
|---|---|
| `better-sqlite3` | GRDB.swift |
| `pdf-parse` / `pdfjs` | PDFKit |
| `epubjs` | Custom EPUB renderer over `ZIPFoundation` + `NSAttributedString` / WebKit |
| `@xenova/transformers` + `hnswlib-node` | Cloud RAG (worker), CoreML deferred |
| `sharp` | `ImageIO` / `UIImage` |
| `safeStorage` | Keychain Services |

## Constraints

- **Tech stack**: SwiftUI + Observation framework + Swift Concurrency. Minimum iOS 18 / iPadOS 18 / macOS 15 (Catalyst) — raised from 17 on 2026-06-11 because the codebase adopted the iOS 18 declarative `Tab`/`TabView(selection:)` SwiftUI 6 API in Phase 12.
- **Distribution**: TestFlight → App Store (iOS, iPadOS) + Mac App Store (Catalyst). No side-loading.
- **App Store compliance**: Sign in with Apple must be offered as a primary option (Guideline 4.8). Subscription handling must respect Apple's review process — Stripe-managed external billing only (out of scope above).
- **Backend**: Reuse existing Cloudflare Worker; no breaking API changes. Worker must add a SIWA token verification endpoint.
- **Codebase**: Native Swift only; no Capacitor / React Native / Flutter. WKWebView used only inside the EPUB renderer if needed for HTML rendering.
- **Data model**: Sync schemas must remain compatible with released clients (`/api/sync/*`) so books, conversations, and highlights continue to round-trip losslessly.
- **Telemetry**: Sentry, opt-in by default in TestFlight, prompt for opt-in in production per Apple privacy guidelines.

## Key Decisions

| Decision | Rationale | Outcome |
|---|---|---|
| iPhone + iPad + Mac Catalyst from v1 (skip visionOS) | Single SwiftUI codebase covers 3 form factors with minimal overhead; visionOS is a niche tail | — Pending |
| All-native (no WKWebView reader, no RN port) | Best perf, best App Store reception, best long-term maintainability; matches Apple-platform expectations | — Pending |
| Sign in with Apple as primary | App Store requires SIWA if any third-party OAuth is offered; making it primary simplifies the UX | — Pending |
| Reuse worker + R2 sync (no CloudKit) | Single source of truth; sync remains compatible with released-client data | — Pending |
| Defer on-device transformer embeddings → cloud RAG only in v1 | Drops the biggest porting risk (`@xenova/transformers` is impossible on iOS as-is) and keeps app size small; CoreML embeddings are a v2 optimization | — Pending |
| Stripe + billing portal handoff (no IAP) in v1 | Avoid Apple IAP migration scope creep; ship parity first | **Reversed in Phase 13** — chose native StoreKit 2 IAP (Path A) over Reader App entitlement (Path B); Stripe portal removed entirely |
| SwiftUI + Observation + Swift Concurrency (no TCA, no UIKit) | Modern iOS 17+ stack, fastest velocity, fewest dependencies | — Pending |
| MOBI / AZW3 deferred | Long tail; EPUB + PDF cover the common case | — Pending |

---
*Last updated: 2026-09-15 to record the Electron archive boundary.*
