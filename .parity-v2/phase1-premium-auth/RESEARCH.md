# Phase 1 Premium Auth Gating — Research Report

Date: 2026-05-22
Author: researcher agent
Next: architect reads this → produces ARCH.md

---

## 1. Current Electron Implementation

### 1.1 Data Types — features.ts

File: `apps/rishi-electron/src/renderer/src/components/auth/features.ts`

Four feature keys: `'tts' | 'chat' | 'voice-input' | 'ai-generic'`.
Each maps to `{ icon: LucideIcon, title, description, bullets[] }`.
The icon field is a `lucide-react` component — web-only, cannot live in shared.

The design spec proposes five keys: `'tts' | 'voice-chat' | 'ai-chat' | 'sync' | 'ai-generic'`.
Electron uses `'chat'` (→ `'ai-chat'`) and `'voice-input'` (kept, used for the mic-in-chat path; the floating launcher maps to `'voice-chat'` under the spec naming).

### 1.2 Pure Gating Logic — useRequireAuth

File: `apps/rishi-electron/src/renderer/src/hooks/useRequireAuth.tsx`

```ts
const isLoggedIn = useAuthStore((s) => s.user !== null)
const requireAuth = useCallback(
  (f: PremiumFeature, action: () => void) => {
    if (isLoggedIn) { action() }
    else { setFeature(f); setOpen(true) }
  },
  [isLoggedIn]
)
const AuthDialog = <PremiumFeatureDialog open={open} onOpenChange={setOpen} feature={feature} />
return { requireAuth, AuthDialog }
```

The hook returns a JSX node (`AuthDialog`) alongside the gate function. On mobile the hook will return booleans and the sheet is mounted separately in the screen. The pure predicate — `user === null` → show gate — has zero DOM dependency.

### 1.3 Dialog Component — PremiumFeatureDialog

File: `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx`

Renders a shadcn `<Dialog>` with: icon + title in header, description, optional bullet list, "Maybe later" (dismiss) and "Sign in" buttons.

Key flow:
- "Maybe later" → `onOpenChange(false)` only. The pending action closure is dropped.
- "Sign in" → `onOpenChange(false)` then `openSignIn()` → sets `authStore.signInOpen = true`.
- `SignInModal` observes that flag and renders. Session arrives async via deep-link/OAuth.
- Pending action is NOT auto-retried after sign-in — the user taps the feature again.

### 1.4 Sign-In Flow — SignInModal

File: `apps/rishi-electron/src/renderer/src/components/auth/SignInModal.tsx`

Magic-link email (`window.api.auth.startMagicLink`) or Google OAuth (`window.api.auth.startGoogle`). Both route through main-process IPC. Modal auto-closes when `useHydrateAuth` fires `onSessionChange`. MAS builds hide Google button. The modal is controlled by `authStore.signInOpen`.

On mobile, sign-in is an Expo Router screen (`/(auth)/sign-in`), not an in-memory modal. The `PremiumFeatureSheet` must call `router.replace('/(auth)/sign-in')` directly.

### 1.5 WelcomeModal

File: `apps/rishi-electron/src/renderer/src/components/auth/WelcomeModal.tsx`

Shown to first-time unauthenticated users. Guards: `!welcomeSeen && authHydrated && !user && !signInOpen`. Mobile already has the welcome banner logic in `authStore`. The `PremiumFeatureSheet` is a separate surface.

### 1.6 Electron authStore Shape

```ts
user: AuthUser | null
authHydrated: boolean
welcomeSeen: boolean
signInOpen: boolean
openSignIn(): void
closeSignIn(): void
```

---

## 2. All requireAuth( Call Sites in Electron

Ten call sites across four reader views and two floating widgets.

| # | File | Feature | Gated action |
|---|---|---|---|
| 1 | `components/tts/TTSControls.tsx:139` | `'tts'` | initial play only; pause/resume bypass |
| 2 | `hooks/reader/useCommonMenuHandlers.ts:60` | `'tts'` | menu "Read Aloud" |
| 3 | `hooks/reader/useCommonMenuHandlers.ts:62` | `'chat'` | open AI chat panel |
| 4 | `hooks/reader/useCommonMenuHandlers.ts:66` | `'voice-input'` | start voice chat |
| 5 | `components/epub/EpubView.tsx:730` | `'tts'` | "Read aloud from selection" |
| 6 | `components/chat/VoiceChatLauncher.tsx:31` | `'voice-input'` | floating mic button |
| 7 | `components/pdf/components/pdf.tsx:432` | `'tts'` | PDF menu read aloud |
| 8 | `components/pdf/components/pdf.tsx:434` | `'chat'` | PDF menu chat |
| 9 | `components/pdf/components/pdf.tsx:438` | `'voice-input'` | PDF menu voice chat |
| 10 | `components/azw3/Azw3View.tsx` | via `useCommonMenuHandlers` | same three |

---

## 3. Mobile Call Sites That Need Gating

| Surface | File:approx-line | Current | Desired |
|---|---|---|---|
| EPUB TTS initial play | `app/reader/[id].tsx:560` | direct send | `requireAuth('tts', ...)` |
| TTS Controls play button | `components/TTSControls.tsx:39` | direct send when idle | `requireAuth('tts', ...)` when idle |
| Realtime voice toggle (start) | `app/reader/[id].tsx:673` | direct activate | `requireAuth('voice-chat', activate)` |
| Voice mic start in chat | `app/chat/[bookId].tsx:67` | direct record | `requireAuth('voice-input', record)` |
| AI chat text send | `app/chat/[bookId].tsx:123` | direct query | `requireAuth('ai-chat', send)` |
| New conversation | `app/(tabs)/chat.tsx:31` | direct picker | `requireAuth('ai-chat', picker)` |
| Reader chat nav button | `app/reader/[id].tsx:664` | direct nav | `requireAuth('ai-chat', nav)` |

---

## 4. Bottom-Sheet Library Decision

`@gorhom/bottom-sheet@^5.2.8` is already present in `apps/mobile/package.json` (line 19). Already used in EPUB reader for six sheet surfaces.

**Decision: use `@gorhom/bottom-sheet` for `PremiumFeatureSheet`.** No new dependency.

**Prerequisite:** `GestureHandlerRootView` must wrap the entire app. Currently only wraps the EPUB reader screen. Move it to `apps/mobile/app/_layout.tsx`.

---

## 5. Existing packages/shared/src/auth Contents

`auth/index.ts` exports only `pkce` and `startAuthSession` — PKCE OAuth primitives. No gating logic.
`auth-gating/` does not exist yet. Phase 1 creates it from scratch.

---

## 6. Mobile 401 Handling (Reactive, In Place)

`apps/mobile/lib/api.ts:58-69` — on 401: `signOut()` + `clearSession()` + throw. This is **reactive** gating. The premium-feature gate is **proactive**. Both required.

---

## 7. Risks

### R1 — Feature key rename breaks electron call sites
Electron uses `'chat'`/`'voice-input'` (10 call sites). Shared uses `'ai-chat'`/`'voice-chat'`. Update electron call sites in the same PR.

### R2 — Pending action not auto-resumed (by design for Phase 1)
User signs in then taps feature again. Phase 1 accepts; Phase 6 could persist + auto-resume.

### R3 — icon field is web-only
`lucide-react` not in RN. Shared `FeatureCopy` omits icon. Each platform maps locally:
- Electron: `PremiumFeature → LucideIcon`
- Mobile: `PremiumFeature → Ionicons name` (per UI-SPEC)

### R4 — openSignIn() differs between platforms
Electron sets store flag → modal. Mobile uses `router.replace('/(auth)/sign-in')`. Sheet calls navigation directly, not the store flag.

### R5 — authHydrated: false cold-start window
When `!authHydrated`, treat as "optimistically logged in" to avoid false-positive gates. Reactive 401 handler catches edge cases.

### R6 — GestureHandlerRootView must be at root
Move to `apps/mobile/app/_layout.tsx`. Unblocks Phase 2's `Sheet` primitive too.

---

## 8. Recommended Extraction Shape

### packages/shared/src/auth-gating/types.ts

```ts
export type PremiumFeature =
  | 'tts' | 'ai-chat' | 'voice-chat' | 'voice-input' | 'sync' | 'ai-generic'

export interface FeatureCopy {
  title: string
  body: string
  cta: string
  bullets: string[]
}
```

### packages/shared/src/auth-gating/feature-copy.ts

Single source of truth — see UI-SPEC.md for final copy.

### packages/shared/src/auth-gating/should-gate.ts

```ts
export function shouldGate(
  user: { id: string } | null,
  _feature: PremiumFeature
): boolean {
  return user === null
}
```

### Electron rewire (no UX change)

1. `PremiumFeatureDialog` imports `FEATURE_COPY` from `@rishi/shared/auth-gating`.
2. Local `features.ts` becomes an icon-mapping shim re-exporting shared types.
3. Call sites updated: `'chat'` → `'ai-chat'`, VoiceChatLauncher `'voice-input'` → `'voice-chat'`.

### Mobile new files

- `apps/mobile/hooks/useRequireAuth.ts` — reads `user`+`authHydrated`, exposes `requireAuth(feature, action)`.
- `apps/mobile/components/PremiumFeatureSheet.tsx` — `@gorhom/bottom-sheet` single-snap-point sheet.
- `apps/mobile/app/_layout.tsx` — wrap with `GestureHandlerRootView`.

---

## 9. Essential Files Reference

### Electron (read-only reference)
- `apps/rishi-electron/src/renderer/src/hooks/useRequireAuth.tsx`
- `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx`
- `apps/rishi-electron/src/renderer/src/components/auth/features.ts`
- `apps/rishi-electron/src/renderer/src/components/auth/SignInModal.tsx`
- `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx`
- `apps/rishi-electron/src/renderer/src/components/chat/VoiceChatLauncher.tsx`
- `apps/rishi-electron/src/renderer/src/hooks/reader/useCommonMenuHandlers.ts`
- `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`
- `apps/rishi-electron/src/renderer/src/components/azw3/Azw3View.tsx`
- `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx`

### Mobile (files to modify)
- `apps/mobile/lib/stores/authStore.ts`
- `apps/mobile/app/reader/[id].tsx`
- `apps/mobile/app/chat/[bookId].tsx`
- `apps/mobile/app/(tabs)/chat.tsx`
- `apps/mobile/components/TTSControls.tsx`
- `apps/mobile/components/RealtimeVoiceButton.tsx`
- `apps/mobile/components/VoiceMicButton.tsx`
- `apps/mobile/components/ChatInput.tsx`
- `apps/mobile/components/ReaderToolbar.tsx`
- `apps/mobile/app/_layout.tsx` (add GestureHandlerRootView)

### Shared (files to create/modify)
- `packages/shared/src/auth-gating/types.ts` (NEW)
- `packages/shared/src/auth-gating/feature-copy.ts` (NEW)
- `packages/shared/src/auth-gating/should-gate.ts` (NEW)
- `packages/shared/src/auth-gating/index.ts` (NEW)
- `packages/shared/src/index.ts` (export auth-gating)
