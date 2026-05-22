# Mobile Parity v2 — Design

Date: 2026-05-22
Status: Approved, in execution
Working dir: `.parity-v2/`

## Context

Parity Loop (v1) completed 2026-05-21. Shared packages (`packages/shared/src/{machines,voice-chat,tts,auth,formats,sync,book-import}`) are in place. Mobile reaches functional parity with electron on backend behavior, but six gaps remain:

1. Premium feature auth gating (electron has `useRequireAuth` + `PremiumFeatureDialog`, mobile has nothing)
2. Reader UI quality below Apple Books bar — user reports "ugly"
3. Floating widgets (G31 from v1, deferred): no `AIChatOrb`, no `VoiceChatLauncher`, no `MiniPlayer` on mobile
4. Voice chat + reader correctness not exhaustively verified across all formats
5. Electron-parity audio cues (ready chime, thinking sound) missing
6. Shared-package extraction could continue (premium-feature config)

Electron is the trusted reference. Its functionality MUST NOT change; only extractions from electron into `packages/shared` are permitted, and electron must keep building/passing its tests after each extraction.

## Goals

- Mobile feels Apple-Books-polished: serif type stack, generous margins, hairline dividers, soft haptics, restrained motion
- Premium features (TTS, voice chat, AI chat) prompt sign-in via a beautiful bottom sheet when signed out
- Voice chat + reader behave identically to electron on every supported format (EPUB, PDF, MOBI, DJVU, AZW3)
- Floating widgets (`AIChatOrb`, `VoiceChatLauncher`, `MiniPlayer`) present on every reader screen, draggable, persistent across navigation
- Electron and mobile share the same XState machines + shared types — no behavioral drift
- Tests green: `pnpm -C packages/shared test`, `pnpm -C apps/mobile test`, `pnpm -C apps/rishi-electron typecheck`

## Non-goals

- Page-curl gesture (G30) — deferred
- Onboarding tour parity beyond what exists (G28 — tour persistence) — explicit "by design" per v1
- Changing electron functionality
- Changing the backend worker (auth/sync/RAG endpoints stable)

## Six-phase execution

### Phase 1 — Premium auth gating

**Extract:** `packages/shared/src/auth-gating/`
- `PremiumFeature` enum: `'tts' | 'voice-chat' | 'ai-chat' | 'sync' | 'ai-generic'`
- `featureCopy: Record<PremiumFeature, { title; body; cta }>` — single source of truth for sign-in prompts
- Pure logic: `shouldGate(user, feature) → boolean`

**Electron rewire:** `useRequireAuth` consumes shared types/config; `PremiumFeatureDialog` reads `featureCopy` from shared. No UX change.

**Mobile new:** `useRequireAuth` hook + `PremiumFeatureSheet` (RN bottom sheet — `@gorhom/bottom-sheet` or native modal, depending on existing deps). Wired into TTS controls, voice mic, AI chat triggers.

**Done when:** TTS button on a signed-out mobile session shows the sheet; signing in via the sheet returns to and continues the original action.

### Phase 2 — Design system foundation

**Tokens** (`apps/mobile/lib/theme/tokens.ts`):
- Color: light + dark, semantic (background.primary, text.primary, separator.opaque, fill.tertiary)
- Type: SF Pro Display (sans), New York / Charter (serif for book text)
- Spacing: 4-pt grid
- Motion: spring presets matching iOS (gentle, snappy)
- Elevation: subtle shadows + soft blur surfaces

**Primitives** (`apps/mobile/components/ui/`):
- `Sheet` (bottom sheet — detents, grabber, backdrop)
- `Toolbar` (top/bottom, glass blur, hairline)
- `IconButton` (hit-slop, press scale, optional haptic)
- `Hairline` (1px / scale)
- `PressableScale` (springy press affordance)
- `BookCover` (rounded, shadow, fallback)

**Screenshot loop:** build → simulator screenshot → critique against Apple Books → refine.

### Phase 3 — Reader UI redesign

Apply Phase 2 to readers. Key changes:
- Minimal chrome — tap-to-toggle top + bottom toolbars
- Bottom toolbar: chapter title (left), progress pill (center), action cluster (right: TOC, bookmark, highlights, appearance, search)
- Sheets for everything (TOC, bookmarks, highlights, appearance, search)
- Page-turn: subtle paginate animation, no curl
- Per-format adapter screens wrap a single `<ReaderShell>` that holds toolbars + sheets

Apply to: `app/reader/[id].tsx` (EPUB), `app/reader/pdf/[id].tsx`, `app/reader/mobi/[id].tsx`, `app/reader/djvu/[id].tsx`, plus AZW3.

### Phase 4 — Floating widgets

**`AIChatOrb`** (mobile) — Reanimated 3 worklet animating 4 vertical bars; states match electron (`idle | connecting | thinking | speaking`); colors match electron (blue/amber/green/purple).

**`VoiceChatLauncher`** (mobile) — mic affordance; tap to start voice chat; Skia or Reanimated breathing animation; same FSM as electron via shared `voice-chat` machine.

**`MiniPlayer`** (TTS) — appears when player has paragraph + status ≠ idle and reader screen is not focused; persists across navigation; tap to return.

All three mount in a top-level `<ReaderOverlay>` that is rendered above reader screens. Positions safe-area aware. Light drag-to-reposition (single saved position in MMKV).

### Phase 5 — End-to-end correctness

**Flows verified end-to-end** (per format: EPUB / PDF / MOBI / DJVU / AZW3):
1. Open book → reader renders → toolbar appears on tap
2. TTS: play → pause → resume → seek → finish chapter
3. Voice chat: connect → speak → interrupt TTS → finish → TTS resumes
4. AI chat (text): ask question → citations render → tap citation → reader jumps
5. Highlights: select → annotate → list → tap → reader jumps
6. Sign-out mid-action: graceful redirect to /(auth)/sign-in

**Electron parity audio:** port `readyChime` + `thinkingSound` to mobile via expo-audio (or react-native-sound).

**Bugs:** use `systematic-debugging` skill on any failures.

### Phase 6 — Polish loop

Iterate via simulator screenshots:
- Hold next to Apple Books screenshots, critique
- Adjust spacing, type weight, color contrast, motion timing
- Haptics calibrated (light for taps, soft for toggles, success/warning for state transitions)
- Final accessibility pass (Dynamic Type, VoiceOver labels)

## Agent team protocol

Each phase runs a fixed pipeline. Agents communicate via files in `.parity-v2/phase{N}/`:

| Agent | Output | Skill / subagent |
|---|---|---|
| researcher | `RESEARCH.md` | feature-dev:code-explorer |
| designer | `UI-SPEC.md` (mockups) | gsd-ui-researcher |
| architect | `ARCH.md` (file plan, contracts) | feature-dev:code-architect |
| tester | `TESTS.md` + failing test commits | team-tester |
| coder | green commits | team-coder |
| reviewer | `REVIEW.md` (≥80% confidence) | team-reviewer |
| screenshot-critic | screenshots + `CRITIQUE.md` | general-purpose + Bash |

TDD red-green-refactor enforced: tester commits before coder.

Atomic commits per task. Conventional Commit messages. No `--no-verify`.

## Coexistence with electron

After every shared-package extraction:
- Run `pnpm -C apps/rishi-electron typecheck` — must be clean
- Run electron's vitest suite on touched paths — must be green
- If anything breaks: revert and adapt the extraction (electron is the trusted reference)

## Verification gates

End of each phase, evidence required before marking complete:
- `pnpm -C packages/shared test` — green
- `pnpm -C apps/mobile test` — green (≤2 pre-existing failures from v1 baseline allowed)
- `pnpm -C apps/rishi-electron typecheck` — green
- Phase-specific E2E/screenshot deliverables

## Risk register

- **R1: RN bottom-sheet lib choice.** `@gorhom/bottom-sheet` is mature but heavy. Fallback: native Modal with custom backdrop. Decision in Phase 1 research.
- **R2: Reanimated 3 worklet shape for AIChatOrb.** Web has CSS keyframes; RN needs `useDerivedValue` + `withRepeat`. Higher fidelity but more code.
- **R3: react-native-skia bundle size.** Only used for `VoiceChatLauncher` waveform — evaluate vs pure Reanimated in Phase 4.
- **R4: Electron extraction regressions.** Mitigation: typecheck + tests after each extraction; rollback if either fails.
- **R5: Voice chat flakes.** Realtime WebRTC + STUN — must verify on physical device, not just simulator.

## Stop condition

Mobile parity v2 done when:
1. Premium features show sign-in sheet on signed-out users; sign-in continues original action
2. Reader UI matches Apple Books design language on all 5 formats
3. AIChatOrb + VoiceChatLauncher + MiniPlayer mounted, animating per electron states
4. All 6 flows from Phase 5 pass on all 5 formats (manual + automated where possible)
5. All test suites + electron typecheck green
6. Screenshots captured at `.parity-v2/screenshots/final/` show the polish

## Out of scope (explicit)

- Page curl gesture (G30)
- Onboarding tour mid-step resume (electron-parity "restart at 0" remains)
- Auto-updater
- Native menu
- Multi-window
- Local-file protocol
