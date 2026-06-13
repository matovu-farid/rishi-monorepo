# Contributing to Rishi for Apple

Welcome. This document is the "start here" for the iOS, iPad, and Mac
Catalyst app. If you read only one thing, read this page.

## What this is

Rishi for Apple is a native SwiftUI port of an existing Electron desktop
app called Rishi. It is a personal book reader for PDF and EPUB files,
with text chat about the book, live voice chat, text-to-speech
read-aloud, and sync of library, positions, highlights, and
conversations across all your Apple devices. The backend is a Cloudflare
Worker. The app runs on iPhone, iPad, and the Mac via Mac Catalyst
(Apple's way of shipping an iPad app as a Mac app).

## The mental model in 60 seconds

There is one Xcode app target, `rishi/`, that owns the app shell, the
top-level navigation, and the composition root (the single place where
services are wired together). Everything else lives in local Swift
packages under `Packages/`. Read package names like folders: each one
owns one slice of the app. Feature packages (`RishiLibrary`,
`RishiReader`, `RishiChat`, `RishiVoice`, `RishiAudio`, `RishiBilling`,
`RishiAuth`, `RishiSync`, `RishiOnboarding`, `RishiSettings`) sit on top
of foundation packages (`RishiCore` for shared types, `RishiDB` for the
on-device database, `RishiAPI` for the Cloudflare Worker client,
`RishiUIKit` for shared colors and typography, `RishiLogging`,
`RishiTesting`). A feature can import a foundation; the reverse is
forbidden by the package manifests.

## Reading order

If you are reading top to bottom rather than looking up a specific
feature, follow this sequence. Each page ends with a "Next:" link
pointing to the next one.

1. **This page (`README.md`)** — what the app is, the mental model, how
   to build and test.
2. **[foundations.md](foundations.md)** — the horizontal packages every
   feature builds on (Core, DB, API, UIKit, Logging, Testing). Read
   this before any feature page; the vocabulary it introduces shows up
   everywhere else.
3. **[architecture/feature-map.md](architecture/feature-map.md)** —
   navigational reference: feature → primary package → also-touches.
   Use this whenever you ask "where is X handled?"
4. **[features/library.md](features/library.md)** — the entry-point
   feature. What the user sees when they open the app.
5. **[features/auth.md](features/auth.md)** — sign-in. Read before any
   cloud-touching feature (sync, chat, voice, billing all assume an
   authenticated user).
6. **[features/reader.md](features/reader.md)** — the heart of the app:
   PDF + EPUB reading, highlights, themes, position persistence.
7. **[features/sync.md](features/sync.md)** — how local reader state
   (positions, highlights, conversations) travels to the worker and
   back.
8. **[features/chat.md](features/chat.md)** — text chat over a book.
9. **[features/voice.md](features/voice.md)** — real-time voice
   conversation.
10. **[features/audio-tts.md](features/audio-tts.md)** — text-to-speech
    read-aloud.
11. **[features/billing.md](features/billing.md)** — StoreKit, paywall,
    entitlements.
12. **[features/onboarding.md](features/onboarding.md)** — first-run
    flow.
13. **[features/settings.md](features/settings.md)** — settings screen
    and preferences.
14. **[architecture/package-consolidation.md](architecture/package-consolidation.md)** —
    historical reference: which packages we considered merging, why we
    deferred. Optional reading.

## Where to look for a feature

| If you want to work on… | Read |
| --- | --- |
| Browsing books, importing books, deleting books | [features/library.md](features/library.md) |
| Reading a PDF or EPUB, highlights, themes, TOC | [features/reader.md](features/reader.md) |
| Text chat over a book with streaming replies | [features/chat.md](features/chat.md) |
| Live voice conversation with the assistant | [features/voice.md](features/voice.md) |
| Read-aloud / text-to-speech playback | [features/audio-tts.md](features/audio-tts.md) |
| Syncing books, positions, highlights across devices | [features/sync.md](features/sync.md) |
| Sign in with Apple, Sign in with Google, sessions | [features/auth.md](features/auth.md) |
| Subscriptions, paywall, StoreKit | [features/billing.md](features/billing.md) |
| First-run experience | [features/onboarding.md](features/onboarding.md) |
| Settings screen, preferences | [features/settings.md](features/settings.md) |
| Foundation layers (Core, DB, API, UIKit) | [foundations.md](foundations.md) |

## How to build and test locally

Build the whole app the way Xcode does it:

```
xcodebuild -project apps/apple/rishi/rishi.xcodeproj \
  -scheme rishi -destination 'generic/platform=iOS Simulator' build
```

Test a single package fast (this is what you should reach for first
while iterating):

```
swift test --package-path apps/apple/Packages/RishiLibrary
```

Every package has its own scheme and its own tests. Running them one at
a time is much faster than rebuilding the whole app, and it is the
recommended way to verify a change.

One important rule. Do not run `xcodebuild rishi` from inside an
automated agent or subagent — the build can take longer than the watchdog
allows and the process gets killed mid-stream. See `apps/apple/CLAUDE.md`
for the full rule and the per-file fallback (`xcrun swiftc -typecheck`).

## Conventions worth knowing

- We use Swift Testing (the new framework with `@Test` and `#expect`),
  not the older XCTest. New tests should follow that.
- No emojis anywhere — not in code, not in comments, not in commit
  messages. This is a project rule.
- Commits are small and atomic, one logical change per commit, with a
  conventional-commits prefix: `feat:`, `fix:`, `test:`, `docs:`,
  `style:`, `refactor:`, `chore:`.
- The app target builds with Swift 6 strict concurrency and the
  default-isolation setting set to MainActor. Translation: every
  function in the app target runs on the main thread unless you mark
  it otherwise. Off-load expensive work with
  `Task.detached(priority: .userInitiated) { ... }`. See
  `docs/SWIFT-CONCURRENCY-RULES.md` for the patterns the project has
  committed to.
- Do not invoke `xcodebuild rishi` from a subagent (watchdog hazard,
  see above).

## Why packages, not one target

Apple's own SwiftUI tutorials use a single app target. This project
deliberately does not. The split was a Phase 1 decision and is worth
understanding before you propose changes to it.

The benefits: each package can be tested in isolation with `swift test
--package-path`, which runs in seconds instead of the minutes a full app
build needs; the package manifests act as a compile-time barrier between
layers (RishiUIKit literally cannot import RishiSync because the
manifest does not list it as a dependency); and Swift 6 strict
concurrency rules are much easier to reason about one small module at a
time.

The cost is real: every type crossing a package boundary has to be
`public`, the IDE sometimes resolves modules slowly, and there is more
boilerplate adding a package. Accept this as the trade.

## Where the planning docs live

The `.planning/` directory at the root of the iOS app holds the project
roadmap, per-phase plans, research notes, and verification reports. It
is gitignored on purpose and should not be committed. Shipped
documentation that lives with the code — including this README and
everything under `features/` — lives in `apps/apple/docs/`. If you write
new contributor-facing docs, put them here.

Read `apps/apple/CLAUDE.md` for the durable per-orchestration rules:
allowed commit paths, the build-first review rule, and the engines we
have committed to keeping (Readium, PDFKit, GRDB, Better Auth, StoreKit,
AVFoundation).
