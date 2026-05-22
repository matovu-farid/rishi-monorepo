# Phase 6 Critique — Validated Findings

Validation date: 2026-05-22. Each P0/P1 finding was opened at the cited file:line and the described code was matched against the current tree at `apps/mobile`. P2/P3 items were left as a deferred backlog without per-item verification (counts below).

## Summary
- Total P0/P1 findings reviewed: 36 (after merging duplicates across critiques)
- CONFIRMED: 35
- PARTIAL: 1 (CHT-002 — context wiring partially exists via `useVoiceChat` opts, but the call site in `chatStore.startChat` still passes `{}` so the defect is real)
- REFUTED: 0

Notes:
- NAV-P0-002 and RDR-007 (MOBI/DJVU tap region) merged.
- NAV-P1-003 and CHT-013 root-cause overlap; NAV-P1-003 kept as the P1 routing fix; CHT-013 (deep-link to chunk) stays P2.
- VIS-002 and WGT-006 (Toolbar BlurView fallback) merged.

## Confirmed P0 (must fix)

| ID | Title | File:line | Verdict | Source IDs | Proposed fix | Test idea |
|---|---|---|---|---|---|---|
| P0-A | EPUB/MOBI/DJVU reader open with toolbar (incl. Back) hidden | `apps/mobile/components/reader/ReaderShell.tsx:137,174,210-214`; EPUB `app/reader/[id].tsx:589-595`; MOBI `app/reader/mobi/[id].tsx:448-465`; DJVU `app/reader/djvu/[id].tsx:375-391`; PDF passes `initialToolbarVisible={true}` at `app/reader/pdf/[id].tsx:467` | CONFIRMED | NAV-P0-001 | Pass `initialToolbarVisible={true}` from EPUB/MOBI/DJVU readers, OR default the prop to `true` in `ReaderShell`. Auto-hide still runs after first tap. | Unit test on `ReaderShell` that the bottom-bar is rendered with `visible=true` on initial mount when no `initialToolbarVisible` is passed; Detox: open an EPUB, assert `reader-bottom-bar` visible without tapping. |
| P0-B | MOBI/DJVU tap-to-reveal toolbar only fires in inner 60% × 40% band | `apps/mobile/app/reader/mobi/[id].tsx:505-521`; `apps/mobile/app/reader/djvu/[id].tsx:435-451` | CONFIRMED | NAV-P0-002, RDR-007 | Expand the Pressable to `StyleSheet.absoluteFill` with `pointerEvents="box-only"` and wrap the WebView so taps that miss links/selections fall through to the toggler (mirrors EPUB's single-tap). | Detox: tap top-left and bottom-right edges of MOBI page; assert toolbar appears in both. |
| P0-C | PDF tap-toggle is a 48pt strip glued to top — bottom 90% of page never reveals toolbar | `apps/mobile/app/reader/pdf/[id].tsx:672-689` | CONFIRMED | RDR-008 | Replace the 48pt strip with a full-area Pressable behind the WebView (same approach as P0-B). | Detox: tap PDF page center; assert toolbar appears. |
| P0-D | PDF reader exposes no TOC / Highlights / Bookmarks / Search / Appearance sheets | `apps/mobile/app/reader/pdf/[id].tsx:475` (`sheets={{ noteEditor: true }}`) | CONFIRMED | RDR-001 | Wire `sheets={{ toc, highlights, bookmarks, search, appearance, noteEditor }}` and pass the same handlers as EPUB (`app/reader/[id].tsx:613-640`); fold the legacy `legacyTopRight` outline button into the bottom-bar `onTocPress`. | Unit: bottom-bar IconButtons render with their `on*Press` handlers; integration: tap TOC button on PDF, sheet opens. |
| P0-E | MOBI reader has no TOC/bookmarks/highlights/search/appearance sheets | `apps/mobile/app/reader/mobi/[id].tsx:464` (`sheets={{}}`) | CONFIRMED | RDR-002 | Mount TocSheet against chapter list parsed by MOBI HTML; AppearanceSheet gated by `format !== 'epub'` for font-family. | Integration: open MOBI book, assert TOC + appearance buttons visible. |
| P0-F | DJVU reader has no TOC/bookmarks/appearance sheets | `apps/mobile/app/reader/djvu/[id].tsx:391` (`sheets={{}}`) | CONFIRMED | RDR-003 | Mount AppearanceSheet + BookmarksList + a "Go to page" sheet. | Same pattern as P0-E for DJVU. |
| P0-G | PDF toolbar missing TTS/Realtime/AI-chat/Bookmark | `apps/mobile/app/reader/pdf/[id].tsx:462-482` | CONFIRMED | RDR-004 | Wire `onTTSPress`, `onRealtimePress`, `onChatPress`, `onBookmarkTogglePress` — TTS via `seedPlayerParagraphsFromChunks(...)`; voice via `useRealtimeChat`/`useVoiceChat`; chat via `router.push(/chat/${book.id})`. | Bottom-bar smoke test: every gated icon appears on PDF when handlers are supplied. |
| P0-H | MOBI/DJVU toolbar missing voice-chat/AI-chat/bookmark/search | `apps/mobile/app/reader/mobi/[id].tsx:448-465`; `apps/mobile/app/reader/djvu/[id].tsx:375-392` | CONFIRMED | RDR-005 | Add `onRealtimePress`, `onChatPress`, `onBookmarkTogglePress` (once bookmarks land via P0-E/F). | Same as P0-G. |
| P0-I | Library screen bypasses the design system entirely (Tailwind grays + hardcoded `#0a7ea4`) | `apps/mobile/app/(tabs)/index.tsx:132-223` (also `155`, `183`, `213`) | CONFIRMED | VIS-001 | Replace Tailwind class colors with `useTheme()` tokens (`colors.background.primary/secondary`, `label.secondary`, `accent.primary`); swap FAB for an iOS tinted button or nav-bar `+`. | Snapshot test under light + dark scheme; visual check vs Apple Books. |
| P0-J | Library search yields blank screen (no `ListEmptyComponent`) | `apps/mobile/app/(tabs)/index.tsx:31-39,195-207` | CONFIRMED | STA-002 | Add `ListEmptyComponent` rendered when `searchQuery.trim()` is non-empty: "No books match \"x\"" + "Clear search" button. | Unit on FlatList: with `books.length > 0` and a non-matching query, assert empty-state markup is rendered. |
| P0-K | Generic import error masks the real cause | `apps/mobile/app/(tabs)/index.tsx:62-67` + `apps/mobile/lib/file-import.ts:70-76` | CONFIRMED | STA-001 | Surface `result.stage` from the shared service; map to stage-specific copy (parse / storage-full / permission / picker-cancel). | Mock importer to return `{ ok:false, stage:'parse' }`; assert "Could not parse this EPUB" appears. |
| P0-L | Reader fatal-load error screen is a dead end (`<Text>Book file not available</Text>`) | EPUB `app/reader/[id].tsx:78-84`; PDF `pdf/[id].tsx:433-439`; MOBI `mobi/[id].tsx:426-432`; DJVU `djvu/[id].tsx:350-356` | CONFIRMED | STA-003 | Render full screen with Back arrow + Retry button; distinguish "Couldn't download from cloud" vs "Local file missing". | Render w/ `book=null` → screen shows Back and Retry. |
| P0-M | Conversations tab renders "Unknown Book" rows for missing books and still navigates | `apps/mobile/app/(tabs)/chat.tsx:136-147` | CONFIRMED | STA-004 | Filter rows whose book is missing, or replace with "Book unavailable" affordance offering delete; gate `router.push` on book existence. | Seed a conversation w/ deleted bookId; row should be hidden or show error CTA. |
| P0-N | Multi-conversation routing: tapping any conversation opens `existing[0]` | `apps/mobile/app/chat/[bookId].tsx:100-108` (load) + `app/(tabs)/chat.tsx:144` (push) | CONFIRMED | CHT-001 | Pass `conversationId` as a query param (`/chat/${bookId}?cid=${item.id}`); chat-detail loads that id; create new only when no cid and no existing conversations. | Unit: render `chat/[bookId]` with `cid=B`, assert conv `B` loads even when `existing[0]` is `A`. |
| P0-O | Voice chat activates with empty context (no page text/outline/paragraph) | `apps/mobile/hooks/useVoiceChat.ts:81` + `apps/mobile/lib/stores/chatStore.ts:133-141` | CONFIRMED (PARTIAL: opts-context wiring exists but no caller passes it) | CHT-002 | Wire `ReaderOverlay` (or per-format reader) to gather `pageText`, `outline`, `activeParagraphText`, pass into `chatStore.startChat` (or expose an activation provider through `setChatVoicePort`). | Spy on `port.activate` ctx arg; assert non-empty `pageText`. |
| P0-P | RAG history sent to LLM is one message behind | `apps/mobile/app/chat/[bookId].tsx:141-151` | CONFIRMED | CHT-003 | Build history from `[...messageList, userMsg]` (or pass `text` as a synthetic last `User:` turn before calling `askQuestion`). | Unit on `handleSend`: after first call, captured history includes the just-sent user text. |
| P0-Q | GlobalMiniPlayer hardcodes 49pt tab-bar height | `apps/mobile/components/player/GlobalMiniPlayer.tsx:7,24` + `apps/mobile/components/player/MiniPlayer.tsx:139-140` | CONFIRMED — `useBottomTabBarHeight()` from `@react-navigation/bottom-tabs` is the correct API in Expo Router (works inside the Tabs subtree) | WGT-001 | Mount `GlobalMiniPlayer` inside `(tabs)/_layout.tsx`, read `useBottomTabBarHeight()`, pass to `MiniPlayer`. | Render under custom tab height; offset matches measured height. |
| P0-R | GlobalMiniPlayer still floats 49pt above bottom on `/chat/[bookId]` (no tab bar there) | `apps/mobile/components/player/GlobalMiniPlayer.tsx:18` | CONFIRMED | WGT-002 | Hide on `/chat/`, OR mount only inside `(tabs)/_layout.tsx` (this also implicitly fixes WGT-001). | Render at `/chat/abc`, assert player not mounted. |
| P0-S | Toolbar/reader chrome ships no real BlurView — opaque rgba fallback | `apps/mobile/components/ui/Toolbar.tsx:24-44` | CONFIRMED | VIS-002, WGT-006 | Wrap toolbar background in `<BlurView intensity={80} tint={scheme==='dark'?'systemChromeMaterialDark':'systemChromeMaterial'} style={StyleSheet.absoluteFill}>`; keep rgba as web fallback. | Snapshot under iOS scheme; ensure `<BlurView>` present. |
| P0-T | `useRequireAuth` fires premium action while auth is unhydrated (cold-start gate bypass) | `apps/mobile/components/auth/useRequireAuth.ts:23-29` | CONFIRMED — `(!authHydrated || isAuthenticated) action()` triggers on cold start | GAT-002 | While `!authHydrated`, defer the action (`useEffect` once hydrated) or disable the trigger control; then dispatch to gate vs. action. | Render with `authHydrated=false, isAuthenticated=false`; assert action is NOT called. |
| P0-U | Typed chat message is lost after signing in through gate (no resume) | `apps/mobile/app/chat/[bookId].tsx:307` + `apps/mobile/components/ChatInput.tsx:51-55` + `components/auth/PremiumFeatureSheet.tsx:81-103` | CONFIRMED | GAT-001 | Persist a `pendingAction` (and pending message) in `authStore.openPremiumGate`; replay in the sheet's success branch before `closeGate`. | Unit on `useRequireAuth + sheet`: type → tap send → sign in → message reaches `onSend`. |
| P0-V | Apple sign-in offered by sheet on iOS but no Apple OAuth wired anywhere | `components/auth/PremiumFeatureSheet.tsx:84,129` + `app/(auth)/sign-in.tsx:84-114` | CONFIRMED | GAT-003 | Until Apple is provisioned, always offer "Continue with Google" (or detect provider list at runtime); add an "Other sign-in options" link routing to `/(auth)/sign-in`. | Render sheet on iOS, expect CTA = Google (or guarded by feature flag). |

## Confirmed P1 (should fix)

| ID | Title | File:line | Verdict | Source IDs | Proposed fix | Test idea |
|---|---|---|---|---|---|---|
| P1-A | Chat "Source" tap routes `/reader/${bookId}` for every format (PDF/MOBI/DJVU error) | `apps/mobile/app/chat/[bookId].tsx:168-175` | CONFIRMED | NAV-P1-003 | Reuse `LibraryScreen.handleBookPress` per-format branch — load book, then `/reader/pdf/...`, `/mobi/...`, `/djvu/...`. | Test with PDF book: tap source → lands on PDF reader, not EPUB. |
| P1-B | Deep-link cold-start into `/reader/[id]` or `/chat/[bookId]` strands the user (Back is unguarded) | `app/reader/[id].tsx:286`; `app/reader/pdf/[id].tsx:420`; `app/reader/mobi/[id].tsx:319`; `app/reader/djvu/[id].tsx:301`; `app/chat/[bookId].tsx:212`; no `canGoBack` anywhere | CONFIRMED | NAV-P1-004 | `router.canGoBack() ? router.back() : router.replace('/(tabs)')` for all four readers + chat detail. | Mount reader from cold link; tap Back; assert lands on Library. |
| P1-C | Chat-detail Back target ambiguous (chevron only, no label parity with Apple Books) | `app/chat/[bookId].tsx:210-228` | CONFIRMED | NAV-P1-005 | Render previous-screen label next to chevron (derived from segments or a `from` param). | Open chat from Library vs reader, label differs. |
| P1-D | Sign-in screen has no escape (no "Skip / Browse local books") | `app/(auth)/sign-in.tsx:62-117` | CONFIRMED | NAV-P1-006 | Add a tertiary "Skip for now" link → `setAuthenticating(false)` + `router.replace('/(tabs)')`. | Render sign-in, tap skip, assert lands in tabs. |
| P1-E | Toolbar cannot be pinned — visible-state mutation re-arms 3s timer | `components/reader/ReaderShell.tsx:204-221` | CONFIRMED | RDR-006 | Add a `pinned` flag (long-press Back, or dedicated control) that bypasses the auto-hide. Persist in prefs. | Pin → wait 5s → toolbar still visible. |
| P1-F | AnnotationPopover color swatches are 20pt with no hitSlop | `components/AnnotationPopover.tsx:114-122` | CONFIRMED | RDR-009 | `hitSlop={12}` per swatch, or wrap in 44pt Pressable. | A11y audit: minimum target ≥ 44pt. |
| P1-G | PDF Read/Cancel/Note/Delete/Close buttons are 32pt tall | `app/reader/pdf/[id].tsx:846-851` | CONFIRMED | RDR-010 | Bump `minHeight: 44`, add `minWidth: 44`. | Snapshot/dim audit. |
| P1-H | PDF/MOBI/DJVU nav chevrons are 36×36 (PDF/MOBI) or 32×32 (DJVU) | `app/reader/pdf/[id].tsx:817-822`; `mobi/[id].tsx:570-574`; `djvu/[id].tsx:526-530` | CONFIRMED | RDR-011 | Bump to 44×44 (or add `hitSlop={{ top:8, bottom:8, left:8, right:8 }}`). | A11y audit. |
| P1-I | PDF selection-bar swatches are 22pt with no hitSlop | `app/reader/pdf/[id].tsx:852-856` | CONFIRMED | RDR-012 | Add `hitSlop={{ top:11, bottom:11, left:11, right:11 }}`. | A11y audit. |
| P1-J | EPUB progress pill uses chapter label / raw href — no page % | `app/reader/[id].tsx:579-584` | CONFIRMED | RDR-013 | Use the `progress` arg of `handleLocationChange` (epubjs param 3): `{ kind: 'page', current: Math.round(progress*100), total: 100 }`. | After page turn, pill shows `xx%`. |
| P1-K | MOBI/DJVU readers have no Read-from-selection menu | `app/reader/mobi/[id].tsx`, `app/reader/djvu/[id].tsx` (no `menuItems`) | CONFIRMED | RDR-014 | Inject selection bridge in the WebView template (`window.getSelection` postMessage) and wire to a paragraph-matcher equivalent to `resolveEpubReadFromSelection`. | Select text in MOBI, "Read from here" appears. |
| P1-L | EPUB bottom-bar will overflow on small phones with all 9 icons | `components/reader/ReaderBottomBar.tsx:109-184` + `components/ui/Toolbar.tsx:82-87` | CONFIRMED | RDR-015 | Move highlights/bookmarks/search into an overflow "More" menu (or scroll horizontally). | Render on SE-sized viewport, assert no clipping. |
| P1-M | Orb + VoiceLauncher (z=20) and reader bottom bar (z=10) can overlap; launcher uses fixed offset that doesn't reflow against `bottomBarVisible` | `components/reader/ReaderOverlay.tsx:69,82`; `MiniPlayer.tsx:330`; `ReaderBottomBar.tsx:81` | CONFIRMED | WGT-003 | Introduce `tokens.zIndex = { toolbar:10, overlayChrome:20, sheet:30 }`; reflow launcher offset against `bottomBarVisible` like MiniPlayer does. | Show toolbar; assert launcher above; tap target unobscured. |
| P1-N | MiniPlayer morph uses `screenWidth/2` for center — wrong on iPad / landscape | `MiniPlayer.tsx:180-185` | CONFIRMED | WGT-004 | `(screenWidth - insets.left - insets.right) / 2 + insets.left`, or `onLayout` measurement. | Test in iPad split view; pill is centered. |
| P1-O | MiniPlayer hit-test gap: pill controls receive touches during morph | `MiniPlayer.tsx:415-434` | CONFIRMED | WGT-005 | Gate `pointerEvents` on `expandedValue.value > 0.85` via `useAnimatedReaction`. | Tap pill 50ms after expand; controls do not fire. |
| P1-P | AIChatOrb a11yLabel doesn't re-announce on status change while focused | `components/chat/AIChatOrb.tsx:41-46,199` | CONFIRMED | WGT-007 | Pair with `accessibilityValue={{ text }}` + call `AccessibilityInfo.announceForAccessibility(...)` on status transitions. | VoiceOver test (or jest spy on announce). |
| P1-Q | No Sign-up / Create-account path | `app/(auth)/sign-in.tsx:62-118` + `components/auth/PremiumFeatureSheet.tsx:225-233` | CONFIRMED | GAT-004 | Add "Create account" CTA below primary button; same on bottom sheet as secondary link. | Render sign-in, "Create account" visible and routes correctly. |
| P1-R | "Not now" / dismiss path provides no exit guidance, gated button still re-tappable | `components/auth/PremiumFeatureSheet.tsx:225-233` | CONFIRMED | GAT-005 | Replace "Not now" with "Maybe later" + subline; hide/disable the gated control after dismiss. | Tap dismiss → gated control disabled. |
| P1-S | `voice-chat` and `voice-input` share identical copy | `packages/shared/src/auth-gating/featureCopy.ts:9-18` | CONFIRMED | GAT-006 | Differentiate `voice-input` copy ("Sign in to dictate"). | Snapshot of FEATURE_COPY for distinct titles/bodies. |
| P1-T | No Pro / lock badges on gated controls (TTS / voice / AI / new conversation) | `components/reader/ReaderTopBar.tsx`; `components/reader/ReaderOverlay.tsx`; `app/(tabs)/chat.tsx` | CONFIRMED | GAT-007 | Render a tiny lock-outline / Pro chip when `!isAuthenticated`. | Render when signed-out; lock chip visible. |
| P1-U | LibraryEmptyState uses hardcoded teal + 8pt radius | `components/LibraryEmptyState.tsx:28-49` | CONFIRMED | VIS-003 | Re-implement on top of the `EmptyState` primitive (uses `radius.full` and `colors.accent.primary`). | Snapshot empty state matches design tokens. |
| P1-V | BookRow uses Tailwind grays + hardcoded `#DC2626` | `components/BookRow.tsx:17-54` | CONFIRMED | VIS-004 | Switch to `colors.fill.quaternary` (press), `colors.label.secondary` (subtitle), `colors.accent.error` (destructive); add Hairline between rows. | Theme audit. |
| P1-W | Typography `display-large` is `fontWeight: '600'` (HIG = 700); no letterSpacing | `lib/theme/typography.ts:30` | CONFIRMED | VIS-005 | Set to `fontWeight: '700'`, add `letterSpacing` table per HIG; add `largeTitle` semantic alias. | Snapshot Large Title under light/dark. |
| P1-X | Accent `#0a7ea4` is not iOS systemBlue and not Apple-Books-like | `lib/theme/colors.ts:72,116` | CONFIRMED | VIS-006 | Adopt iOS systemBlue (`#007AFF` / `#0A84FF`) or systemOrange. | Theme token audit; visual diff. |
| P1-Y | Radius tokens missing 16 / 22 (card / sheet sizes) | `lib/theme/tokens.ts:18-25` | CONFIRMED | VIS-007 | Add `card: 12, sheet: 22, cover: 8` (or expand the scale). Document continuous corners caveat. | Lint: radius literal usage in component tree drops to zero. |
| P1-Z | Voice mic permission denial is silent — no Open Settings path | `hooks/useVoiceInput.ts:24-34` + `components/ChatInput.tsx:117-120` | CONFIRMED | STA-005 | When `permissionDenied`, render a Pressable "Open Settings" → `Linking.openSettings()`; document iOS one-shot prompt. | Mock `requestRecordingPermissionsAsync` to deny; assert link is present and tappable. |
| P1-AA | Embedding failure on chat screen leaves input permanently disabled | `app/chat/[bookId].tsx:120-130,182` | CONFIRMED | STA-006 | Capture an `embeddingError` state; render banner "Could not prepare this book — Retry" that re-runs `embedBook`. | Mock embed failure; banner present + retry triggers reload. |
| P1-AB | Library has no loading / skeleton state on first focus | `app/(tabs)/index.tsx:17-51` | CONFIRMED | STA-007 | Add `hasLoadedOnce` flag (or `null` initial state); render skeleton grid until first `getBooks()` returns. | Render with synchronously empty `getBooks`; skeleton shown until load resolves. |
| P1-AC | Cover-extraction failures silently leave letter-tile w/ no retry | `lib/book-import/adapters.ts:402-433` | CONFIRMED | STA-008 | Persist `coverExtractionFailed` flag (or `coverPath = '__failed'`); long-press menu offers "Retry cover extraction". | Mock extract failure; long-press surfaces Retry. |
| P1-AD | URL import error parrots raw fetch status | `components/UrlImportSheet.tsx:41-44`; `lib/file-import.ts:235-238` | CONFIRMED | STA-009 | Map 404 → "We couldn't find that file"; 401/403 → "URL requires permission"; non-2xx → "Server refused download". | Mock fetch responses; assert mapped copy. |
| P1-AE | ConversationRow truncation w/o ellipsisMode + no a11y full title | `components/ConversationRow.tsx:65-83` | CONFIRMED | STA-010 | Add `ellipsizeMode="tail"`, expose full title via `accessibilityLabel`. | A11y snapshot. |
| P1-AF | Library FlatList unvirtualized for 1000+ books | `app/(tabs)/index.tsx:195-207` | CONFIRMED | STA-011 | Swap to `@shopify/flash-list` (already standard), or set `getItemLayout`, `removeClippedSubviews`, `initialNumToRender=12`. | Perf benchmark with 1000-book fixture. |
| P1-AG | Sync error state non-actionable — retry just re-fails silently | `components/SyncStatusIndicator.tsx:60-126`; `lib/sync/engine.ts:36-55` | CONFIRMED | STA-012 | Show toast on tap-retry success/failure; expose last error via accessibilityHint; long-press → sync diagnostics. | Mock sync failure; assert toast + accessibility hint. |
| P1-AH | Conversations "New conversation" Alert hits iOS button limit + book-not-embedded UX is poor | `app/(tabs)/chat.tsx:39-45` | CONFIRMED | STA-013 | Replace Alert with `@gorhom/bottom-sheet` listing imported books with embed-status + CTA "Open in Library". | Render w/ no embedded books; sheet shows CTA, not Alert. |
| P1-AI | ChatInput "stop" icon does nothing (no abort) | `components/ChatInput.tsx:50-56,95-114` | CONFIRMED | CHT-006 | Remove the stop icon (use spinner), OR add `onAbort` prop wired to an `AbortController`. | Spy on apiClient abort; tap "stop" cancels fetch. |
| P1-AJ | No thinking-sound during voice-chat "thinking" state — silent dead-air | `lib/voice-chat/sounds.ts:151-157` | CONFIRMED | CHT-007 | Ship a small `tick.mp3` looped with `expo-audio` OR fire periodic light Haptics during `thinking`. | Unit on sounds.ts: starting thinking sound triggers playback or haptic. |
| P1-AK | Sign-in sheet doesn't guarantee text preservation behind gate; gating-state leaks into input shape | `components/auth/PremiumFeatureSheet.tsx:62-79`; `components/ChatInput.tsx:39-55`; `app/chat/[bookId].tsx:316` | CONFIRMED | CHT-004, CHT-008 | Move "preserve text behind gate" guarantee into `useRequireAuth` (snapshot/restore via store). Default `clearOnSend` to false (or rename to `clearAfterAccepted`); chat detail relies on the hook, not the prop. | Unit on `useRequireAuth`: gated → text preserved; signed in → text cleared. |
| P1-AL | Chat embed runs even when signed out and never surfaces failure | `app/chat/[bookId].tsx:112-130` | CONFIRMED | CHT-005 | Gate `embedBook` behind `requireAIChat` OR surface inline error "Sign in to prepare this book for chat." | Render signed-out chat detail; banner appears, send disabled with reason. |

## Partial / Corrected

| ID | Original claim | Actual issue | New severity | File:line |
|---|---|---|---|---|
| CHT-002 | "Voice chat activates without page text, outline, chapter, or active paragraph" | The hook `useVoiceChat` already accepts an `opts.context: () => VoiceChatContext` provider (line 81), but the live call site is `chatStore.startChat` which passes a literal `{}` (line 133-141). No caller of `useVoiceChat` registers a `context` callback either, so the defect is real but the fix is "wire callers" rather than "rewrite the hook." | Stays P0 | `apps/mobile/hooks/useVoiceChat.ts:81`; `apps/mobile/lib/stores/chatStore.ts:133-141`; `apps/mobile/components/reader/ReaderOverlay.tsx:47-53` |

## Refuted

(None — every P0/P1 finding was reproducible from the cited code.)

## Deferred (P2/P3) — not validated, listed by source file
- `CRITIQUE-navigation.md`: 5 items (NAV-P2-007 .. NAV-P2-011)
- `CRITIQUE-reader.md`: 15 items (RDR-016 .. RDR-030)
- `CRITIQUE-chat.md`: 15 items (CHT-009 .. CHT-023)
- `CRITIQUE-widgets.md`: 9 items (WGT-008 .. WGT-016, incl. one P3)
- `CRITIQUE-gating.md`: 8 items (GAT-008 .. GAT-015, incl. one P3)
- `CRITIQUE-visual.md`: 13 items (VIS-008 .. VIS-020, incl. P3s)
- `CRITIQUE-states.md`: 8 items (STA-014 .. STA-021)

Total deferred: 73 items. To be re-triaged after the P0/P1 backlog lands.

## Fix ordering recommendation

Order chosen to (a) ship the user-reported defect first ("no way to go back to the library"), (b) front-load shared-token/foundation work that subsequent items depend on, (c) group atomic commits by file.

1. **P0-A, P0-B, P0-C** — toolbar visibility & tap-region fixes across `ReaderShell.tsx`, all four reader screens. (Resolves the user-reported "no way to go back" dead end.) Single feature branch, one commit per format.
2. **P0-T (GAT-002)** — invert the cold-start policy in `useRequireAuth.ts`. (Blocks GAT-001 work — premium-action replay needs hydrated state.)
3. **P0-U (GAT-001) + P1-AK (CHT-004 / CHT-008)** — implement pending-action / pending-text replay in `authStore` + `PremiumFeatureSheet`; refactor `ChatInput.clearOnSend` to be driven by the hook. Atomic with P0-T.
4. **P0-S (VIS-002 / WGT-006)** — replace `Toolbar` rgba fallback with `<BlurView>`. Touches one file; unblocks Apple-Books visual parity for every reader chrome use.
5. **P1-W, P1-X, P1-Y (VIS-005/006/007)** — typography weights, accent color, radius scale. **Must precede** P0-I (Library theme migration) and P1-U/V (LibraryEmptyState, BookRow) because those screens consume the tokens.
6. **P0-I (VIS-001) + P1-U (VIS-003) + P1-V (VIS-004)** — migrate library tab, empty state, and book row off Tailwind grays/hardcoded teal onto theme tokens. Single atomic PR.
7. **P0-J (STA-002) + P0-K (STA-001) + P1-AB (STA-007)** — library FlatList empty-state, import-error mapping, loading skeleton. All in `app/(tabs)/index.tsx` + `lib/file-import.ts`.
8. **P0-D / P0-E / P0-F (RDR-001/002/003)** — wire missing reader sheets for PDF/MOBI/DJVU. One commit per reader; depends on token work (step 5) for AppearanceSheet visuals.
9. **P0-G / P0-H (RDR-004/005)** — wire missing toolbar handlers (TTS / voice / AI / bookmark) for PDF + MOBI + DJVU. Commit after sheets land.
10. **P0-Q / P0-R (WGT-001/002)** — move `GlobalMiniPlayer` mount into `(tabs)/_layout.tsx`, read `useBottomTabBarHeight()`.
11. **P0-L (STA-003)** — full-screen reader-error component (Back + Retry). Shared component reused by all four readers.
12. **P0-M (STA-004) + P0-N (CHT-001) + P1-A (NAV-P1-003) + P1-C (NAV-P1-005)** — conversation tab + chat detail navigation cleanup. Atomic per concern but same files.
13. **P0-O (CHT-002) + P0-P (CHT-003)** — voice chat context wiring + RAG history fix. Same file (`chat/[bookId].tsx` + `chatStore.ts` + `ReaderOverlay.tsx`).
14. **P1-B (NAV-P1-004)** — `canGoBack()` guards across all four readers + chat detail. Single search-and-replace commit.
15. **P0-V (GAT-003)** — gate the sheet's Apple CTA behind a feature flag and route to `/(auth)/sign-in` for "Other options".
16. **P1-D (NAV-P1-006) + P1-Q (GAT-004) + P1-R (GAT-005) + P1-S (GAT-006) + P1-T (GAT-007)** — sign-in screen polish: skip, sign-up, dismiss copy, voice-input copy, lock chips. Same surface family.
17. **P1-E (RDR-006)** — toolbar pin.
18. **P1-F .. P1-I (RDR-009/010/011/012)** — touch-target sweep in PDF + AnnotationPopover + MOBI/DJVU nav chevrons.
19. **P1-J (RDR-013)** — EPUB page-progress %.
20. **P1-K (RDR-014)** — MOBI/DJVU selection bridge.
21. **P1-L (RDR-015)** — bottom-bar overflow menu on small phones.
22. **P1-M / P1-N / P1-O (WGT-003/004/005)** — MiniPlayer + ReaderOverlay layering, iPad center, hit-test guard.
23. **P1-P (WGT-007)** — AIChatOrb a11y re-announce.
24. **P1-Z (STA-005) + P1-AA (STA-006) + P1-AC (STA-008) + P1-AD (STA-009) + P1-AE (STA-010) + P1-AF (STA-011) + P1-AG (STA-012) + P1-AH (STA-013) + P1-AI (CHT-006) + P1-AJ (CHT-007) + P1-AL (CHT-005)** — degraded-state polish: mic permission, embedding error, cover retry, URL-import copy, conversation row truncation, FlashList, sync diagnostics, new-conversation sheet, ChatInput stop/abort, thinking sound, embed gate. Mostly independent commits; order by file proximity.

**Cross-cutting prerequisites (call out):**
- Steps 5 (tokens) must land before steps 6, 8, P1-U/V — many screens import from `lib/theme`.
- Steps 2-3 (auth pending-action infrastructure) must land before P1-AK — both share the authStore changes.
- Step 4 (BlurView) must land before any chrome-visual snapshot tests are recorded.
