# Feature -> Package Map

When you want to work on a feature, look here to find which packages are
involved. "Primary" = where the feature's logic and UI live. "Also touches"
= packages that get imported or whose contracts the feature depends on.

RishiCore and RishiLogging are imported by almost every feature package and
are omitted from "Also touches" unless the feature explicitly extends them.
RishiUIKit (design tokens) is imported by every feature with UI and is also
omitted by default.

## User-facing features

| Feature | Primary package | Also touches |
|---|---|---|
| Onboarding (first-run flow) | RishiOnboarding | RishiLibrary, RishiAuth (via app), RishiCore |
| Sign-in / sign-up | RishiAuth | RishiAPI, RishiCore (`AuthService` protocol) |
| Library: browse books | RishiLibrary | RishiDB (storage), RishiCore (`Book`, `BookStore`) |
| Library: import book (file picker) | RishiLibrary (`Import/`) | RishiDB |
| Library: search | RishiLibrary (`Search/`) | RishiDB |
| Library: delete / archive book | RishiLibrary | RishiDB |
| Reading: PDF | RishiReader (`PDF/`) | RishiDB (positions), RishiCore (`Position`, `Highlight`) |
| Reading: EPUB | RishiReader (`EPUB/`) | RishiDB (positions), RishiCore |
| Reading: highlights / annotations | RishiReader | RishiDB, RishiCore (`Highlight`, `HighlightStore`) |
| Reading: page-position sync | RishiReader + RishiSync | RishiDB, RishiAPI |
| Reading: prewarm / preview | RishiReader (`Prewarm/`) | — |
| Reader toolbar / chrome | RishiReader (`UI/`) | RishiUIKit |
| Text-to-speech playback | RishiAudio (`TTS/`) | RishiAPI (TTS endpoint), RishiSettings (voice prefs) |
| Audio session coordination | RishiAudio (`Coordinator/`) | — |
| Voice chat (WebRTC) | RishiVoice | RishiAudio (session coord), RishiAPI |
| Voice permissions UX | RishiVoice (`Permissions/`) | — |
| Chat: conversations list | RishiChat (`Storage/`) | RishiDB, RishiCore (`Conversation`, `ConversationStore`) |
| Chat: messages / streaming | RishiChat (`Service/`) | RishiAPI, RishiCore (`Message`, `ChatService`) |
| Chat: UI | RishiChat (`UI/`) | RishiUIKit |
| Billing: paywall + subscribe | RishiBilling (`UI/` + `StoreKit/`) | RishiAPI (receipt validation) |
| Billing: entitlement gating | RishiBilling (`Entitlements/`) | — (consumed by every premium feature) |
| Settings: account / sign-out | RishiSettings | RishiAuth, RishiAPI |
| Settings: subscription mgmt | RishiSettings | RishiBilling |
| Settings: TTS voice / speed | RishiSettings | RishiAudio |
| Settings: reader prefs | RishiSettings | RishiReader |
| Settings: sync status | RishiSettings | RishiSync |
| Settings: telemetry opt-out | RishiSettings (`Telemetry/`) | RishiLogging |
| Cloud sync (positions, highlights, library) | RishiSync | RishiAPI, RishiDB, RishiCore |

## Cross-cutting infrastructure

| Concern | Package | Notes |
|---|---|---|
| Domain types (Book, User, Conversation, etc.) | RishiCore | Models + protocols. Universal import. |
| API client / network layer | RishiAPI | HTTP, auth headers, retry, contract types. |
| Persistence (GRDB / SQLite) | RishiDB | Schema, migrations, DAOs. |
| Logging / Sentry bridge | RishiLogging | `Log.info`, sinks, simulator dump. |
| Design tokens (colors, spacing, motion) | RishiUIKit | Pure tokens + a few modifiers. |
| Test fakes & helpers | RishiTesting | Linked only by `Tests/` targets. |

## App-target-only code (lives in `apps/apple/rishi/`)

| Concern | Location | Notes |
|---|---|---|
| App lifecycle / scene bootstrap | `rishi/rishi/` | `@main`, root scene. |
| Tab navigation / root routing | `rishi/rishi/` | Wires features into tabs. |
| Push / deep links | `rishi/rishi/` | URL handler glue. |
| Info.plist, entitlements | `rishi/rishi/` | App-target config only. |

## Quick lookups

**"Where do positions get saved?"**
RishiReader writes via `PositionStore` protocol (RishiCore) -> implemented in
RishiDB -> synced by RishiSync via RishiAPI.

**"Where does the audio session get configured for TTS?"**
RishiAudio/Coordinator/AudioSessionCoordinator.swift (also consulted by
RishiVoice when starting a WebRTC session).

**"Where is the paywall shown?"**
RishiBilling/UI/, gated by entitlement check from RishiBilling/Entitlements/.
Triggered from feature packages (RishiChat, RishiAudio TTS, RishiSync) when
a premium feature is hit without entitlement.

**"Where is sign-in handled?"**
RishiAuth/Service/ does the network call (via RishiAPI), stores token via
RishiAuth/Keychain/, exposes session state via RishiAuth/Coordinators/.
The app target wires this into the root scene.

**"Where do test fakes live?"**
RishiTesting/Sources/. Each feature package imports it only from its
`Tests/` target (never from production sources).

---

**Next:** [../features/library.md](../features/library.md) — the entry-point feature: what the user sees when they open the app.
