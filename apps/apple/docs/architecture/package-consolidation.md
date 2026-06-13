# Package Consolidation Proposal

Analysis date: 2026-06-13
Author: subagent analysis (review before acting)

## TL;DR

The `apps/apple/` workspace has 16 local SwiftPM packages totalling ~18.8k LOC.
Three packages (RishiLogging, RishiUIKit, RishiOnboarding) are thin enough that
their separate-package overhead almost certainly exceeds the modularity gain.
A further three (RishiAuth, RishiAudio + RishiVoice pair, RishiSettings) are
plausible merge candidates with real trade-offs. The rest carry their weight.
Total realistic reduction: 16 -> 11 packages. Recommendation: do NOT execute
this before v1.0 ship — the ROI is real but small, and the disruption window
is large.

## Current Inventory

| Package | Files | LOC (code) | Public types | Tests | Imported by | Tier |
|---|--:|--:|--:|--:|---|---|
| RishiAPI | 16 | 1,260 | 43 | 10 | 6 packages + app | A |
| RishiAudio | 20 | 1,714 | 32 | 10 | 2 packages + app | B |
| RishiAuth | 14 | 649 | 16 | 8 | app only | B |
| RishiBilling | 19 | 1,419 | 30 | 19 | 1 package + app | A |
| RishiChat | 17 | 1,235 | 12 | 11 | app only | A |
| RishiCore | 17 | 311 | 21 | 3 | 13 packages + app | A |
| RishiDB | 9 | 847 | 2 | 7 | 1 package + app | A |
| RishiLibrary | 23 | 2,284 | 23 | 16 | 3 packages + app | A |
| RishiLogging | 6 | 376 | 4 | 2 | 12 packages + app | C |
| RishiOnboarding | 9 | 576 | 9 | 4 | app only | C |
| RishiReader | 52 | 4,432 | 48 | 48 | 1 package + app | A |
| RishiSettings | 12 | 804 | 17 | 5 | app only | B |
| RishiSync | 27 | 1,974 | 17 | 23 | 1 package + app | A |
| RishiTesting | 20 | 572 | 8 | 4 | 5 test targets | A (test-only) |
| RishiUIKit | 10 | 347 | 9 | 2 | 9 packages + app | C |
| RishiVoice | 14 | 1,004 | 24 | 9 | app only | B |

Totals: 285 source files, ~18,824 LOC, ~315 public symbols, 181 test files.

Importer counts exclude the package's own test target. "App" = the `rishi/`
app target.

## Proposed Mergers

### Merge 1: RishiLogging -> RishiCore

**Current state:**
- RishiLogging: 6 files, 376 LOC, 4 public types. Owns `Log`, `LogEvent`,
  `LogSink`, `SentryBridge`, `SimulatorDumpSink`.
- RishiCore: 17 files, 311 LOC, the universal domain types module — every
  package already imports it.

**Proposal:** Move `RishiLogging/Sources/RishiLogging/*` into
`RishiCore/Sources/RishiCore/Logging/`. Delete the RishiLogging package
directory and its `.package` entry from each consumer's Package.swift.
Replace `import RishiLogging` with nothing (RishiCore is already imported
everywhere RishiLogging is used).

**Why:**
- 12 of 16 packages import RishiLogging — it is already a de facto universal
  dependency, same shape as RishiCore.
- 4 public types and 376 LOC do not justify a separate module boundary,
  scheme, Package.swift, and test target.
- Reduces import noise at the top of nearly every file.

**Cost:**
- RishiCore becomes slightly heavier (~687 LOC vs 311). Still trivially small.
- Sentry SDK dependency now lives in RishiCore, which means even packages
  that don't log (RishiTesting, hypothetically) link Sentry's headers.
  Likely a non-issue — Sentry is already transitively reachable from the app
  target anyway.
- Loses the option to swap logging implementation per-package — but nobody
  was doing that.

**Effort estimate:** small (2-4 hours). Mechanical move + import sweep.

### Merge 2: RishiUIKit -> RishiCore (or stay, see notes)

**Current state:**
- RishiUIKit: 10 files, 347 LOC. Pure design tokens (colors, typography,
  spacing, radii, motion) + 2 A11y helpers + 1 animation modifier.
- 9 packages + the app import it.

**Proposal A (aggressive):** Fold into RishiCore as `RishiCore/Design/`.
Same logic as RishiLogging — RishiCore is universally imported.

**Proposal B (mild):** Keep separate but rename `RishiDesign` and accept
that 347 LOC of tokens is allowed to be its own thing because design
tokens are a recognized concept.

**Why A:**
- Same reasoning as logging — sub-500 LOC, universally imported, no domain
  identity beyond "shared primitives".
- RishiCore is allowed to grow up to ~1k LOC and remain comprehensible.

**Cost of A:**
- RishiCore now imports SwiftUI (currently it may be Foundation-only). Many
  non-UI packages would transitively link SwiftUI. Marginal cost on iOS, but
  it does muddy "core = platform-agnostic domain types".
- Design tokens have a recognizable identity. Future designers/devs looking
  for them will look for "RishiUIKit" or "RishiDesign", not "RishiCore".

**Recommendation:** This trade-off is closer than Merge 1. If you keep
RishiUIKit separate, do not feel bad — 347 LOC is borderline.

**Effort estimate:** small (2-4 hours) if A; zero if B.

### Merge 3: RishiOnboarding -> app target (Sources/Onboarding/)

**Current state:**
- RishiOnboarding: 9 files, 576 LOC, 9 public types. Imported only by the
  app target. Owns onboarding flow + "have we seen onboarding" storage.

**Proposal:** Move all of `RishiOnboarding/Sources/RishiOnboarding/` into
`apps/apple/rishi/Sources/Onboarding/`. Delete the package. Tests move to
the app target's test bundle (or stay as a feature-test target).

**Why:**
- App-target-only consumer — no module reuse argument.
- Onboarding is one-time-shown UI shell work, not a reusable engine.
- Removing it cuts a Package.swift, a scheme, a public API surface for
  zero functional change.

**Cost:**
- Loses test isolation: the onboarding tests now live in the app target
  test bundle, which is slower to build than a per-package test target.
- App target gets bigger. The app target is already where most "non-engine"
  code lives, so this is consistent with existing structure.
- Harder to extract back into a package later if (unlikely) onboarding ever
  needs to be reused.

**Effort estimate:** small (3-5 hours). Need to update the app target
sources, move tests, update Xcode project.

### Merge 4: RishiAudio + RishiVoice -> RishiAudioStack

**Current state:**
- RishiAudio: 1,714 LOC. AVAudioSession coordinator + TTS engine + audio
  settings UI.
- RishiVoice: 1,004 LOC. WebRTC voice session, permissions, voice UI.
- RishiVoice imports RishiAudio. Both touch the AVAudioSession.

**Proposal:** Merge into `RishiAudioStack` with two submodules:
`AudioStack/TTS/` and `AudioStack/Voice/`, sharing the existing
`AudioSessionCoordinator`.

**Why:**
- Both packages compete for the iOS AVAudioSession singleton. Keeping the
  session coordinator and both consumers in one module makes the "who owns
  the session right now" invariant locally enforceable.
- Saves one package boundary.
- Future audio features (background audio, CarPlay, AirPlay) live in one
  place.

**Cost:**
- Combined size jumps to ~2,700 LOC — large but still under RishiReader.
- Loses the ability to ship a build with TTS but no voice chat (or vice
  versa). Currently RishiVoice could be stripped without touching TTS;
  after merge, both ride together.
- WebRTC is a heavy dependency. If RishiAudio currently has no WebRTC link,
  merging will pull WebRTC into the TTS package's transitive deps. Worth
  verifying before committing.

**Effort estimate:** medium (1-2 days). Has API surface changes, real
import updates in the app, and dependency-graph implications.

### Merge 5: RishiAuth -> app target (Sources/Auth/) — speculative

**Current state:**
- RishiAuth: 649 LOC, 16 public types. Imported only by the app target.

**Proposal:** Move into `apps/apple/rishi/Sources/Auth/` like onboarding.

**Why:**
- Single consumer.
- Auth flows are app-shell-y: Keychain storage + sign-in coordinator + a
  service implementation. Not a reusable engine.

**Cost:**
- 649 LOC is bigger than onboarding. It is on the edge of "earns its own
  module" by size.
- Keychain access is a sensitive code path — keeping it in a small package
  with its own focused tests has security-review value.
- If you ever add a watchOS or Mac Catalyst target sharing auth state, a
  separate package is much easier to wire in.

**Recommendation:** This one is genuinely close. Lean toward keeping
RishiAuth separate unless you are confident there will be no second
client target.

**Effort estimate:** small-medium (4-6 hours).

### Merge 6: RishiSettings absorption — not recommended

Considered folding RishiSettings into either RishiAudio (since most settings
are audio-related) or into the app target. Rejected:
- 804 LOC is large enough to earn its keep.
- Settings reaches into RishiAudio, RishiBilling, RishiReader, RishiSync —
  cross-cutting consumer, no single sensible merge target.
- Keep as-is.

## Packages to Keep Separate

- **RishiCore**: universal domain types module. Merging would break the
  dependency DAG. Keep — but allow it to absorb RishiLogging (and maybe
  RishiUIKit) since it's the universal-leaf anyway.
- **RishiAPI**: 1,260 LOC, imported by 6 sibling packages. Network contract
  module; clear identity. Keep.
- **RishiDB**: 847 LOC, owns GRDB schema/migrations/DAO. Test-critical
  isolation: GRDB needs SQLite link, and isolating it means the rest of the
  app can be type-checked without it. Keep.
- **RishiLibrary**: 2,284 LOC, 3 sibling consumers, owns the book-library
  domain. Keep.
- **RishiReader**: 4,432 LOC, the heaviest package, owns PDF + EPUB rendering.
  Keep — this is the textbook case for a package.
- **RishiSync**: 1,974 LOC. Owns CRDT-ish sync logic. Keep.
- **RishiChat**: 1,235 LOC. App-only consumer but owns enough chat-domain
  state (conversations, messages, streaming) that the package boundary
  forces a clean RishiCore protocol contract. Keep.
- **RishiBilling**: 1,419 LOC, StoreKit code. Highly testable in isolation
  via fakes; merging would erase that. Keep.
- **RishiTesting**: 572 LOC, used only by 5 test bundles. MUST be a
  separate target so production binaries do not link test fakes. Keep —
  hard architectural requirement.

## Risks of the Whole Effort

- **Import sweep blast radius**: every `import RishiLogging` line across the
  codebase changes (or just disappears). Every file touched gets a
  recompile. CI cache invalidates.
- **Xcode project surgery**: schemes for merged packages disappear. Anything
  external referencing those schemes (Xcode Cloud build configs, Fastlane
  lanes, CI workflows) needs updating. Specifically the `rishi.xcscheme`
  + Xcode Cloud workflows in `apps/apple/scripts/` and `fastlane/` need
  audit.
- **Test runtime**: collapsing per-package test targets into the app target
  (Onboarding, Auth if chosen) slows the test loop because the app target
  takes longer to compile than a leaf SwiftPM target.
- **Git history**: file moves across package directories will look like
  delete+add unless `git mv` is used carefully. `git blame` survives but
  some review tools won't follow.
- **Sentry / WebRTC transitive linking**: merging RishiLogging into
  RishiCore means everyone links Sentry. Merging RishiAudio + RishiVoice
  could pull WebRTC into TTS-only consumers. Verify before merging.

## Recommended Sequencing

If the user decides to act, in increasing risk order:

1. **Merge 1 (RishiLogging -> RishiCore)** — lowest risk, highest noise
   reduction.
2. **Merge 3 (RishiOnboarding -> app)** — single-consumer, mechanical.
3. **Merge 2 (RishiUIKit -> RishiCore)** — only if you accept SwiftUI
   leaking into RishiCore.
4. **Merge 5 (RishiAuth -> app)** — only if no second client target is
   planned.
5. **Merge 4 (RishiAudio + RishiVoice -> RishiAudioStack)** — last because
   it has real API surface change and dependency implications.

Stop after step 1 or 2 and revisit. The marginal benefit drops sharply
after the obvious thin packages are absorbed.

## Recommendation

**Do NOT do this before v1.0 ship.**

Honest assessment: the user has built a reasonably clean modular structure.
The "16 packages feels unwieldy" feeling is real but is largely a
navigation problem, not an architecture problem. The right fix for
navigation is the `feature-map.md` companion document, not a re-arch.

The actual structural wins available (RishiLogging, RishiOnboarding,
maybe RishiUIKit) save 1,300 LOC of "thin module" overhead and remove
3 packages. That is genuine but small. Versus the risk of v1.0-eve
churn — broken CI, broken Xcode Cloud, broken schemes, a week of "why
won't this build", invalidated muscle memory for every contributor —
the cost-benefit favors deferral.

**Suggested plan:**
- Ship v1.0 with the current 16 packages.
- Adopt the feature-map doc immediately as a navigation aid.
- Post-v1.0, in a quiet week, do Merges 1 + 3 (RishiLogging into Core,
  RishiOnboarding into app). That is ~1 day of work and is the
  Pareto-optimal slice — 70% of the structural benefit for 20% of the
  effort.
- Revisit Merges 2, 4, 5 only if a concrete pain point (e.g. an audio
  session bug that crosses RishiAudio/RishiVoice) surfaces post-ship.

---

**End of the reading order.** Return to the [contributor README](../README.md) when you're ready to start writing code.
