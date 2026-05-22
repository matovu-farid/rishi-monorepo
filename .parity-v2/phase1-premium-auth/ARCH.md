# Phase 1 — Premium Auth Gating: Architecture Blueprint

Date: 2026-05-22
Author: architect agent
Status: Ready for tester (TDD red) then coder (TDD green)

---

## 1. New files in packages/shared

### 1.1 `packages/shared/src/auth-gating/types.ts`

```ts
export type PremiumFeature =
  | 'tts'
  | 'ai-chat'
  | 'voice-chat'
  | 'voice-input'
  | 'sync'
  | 'ai-generic'

export interface FeatureCopy {
  title: string
  body: string
  cta: string
}
```

Exports: `PremiumFeature` (type), `FeatureCopy` (interface).

Note on `voice-input`: kept in union for electron's chat-panel mic path (distinct from floating launcher). Gets same copy as `voice-chat`.

### 1.2 `packages/shared/src/auth-gating/featureCopy.ts`

camelCase filename, matches shared package convention (`startAuthSession.ts`, `stringToNumberID.ts`).

```ts
import type { PremiumFeature, FeatureCopy } from './types'

export const FEATURE_COPY: Record<PremiumFeature, FeatureCopy> = {
  tts: {
    title: 'Sign in to listen',
    body: 'Sign in to hear your books read aloud in expressive voices.',
    cta: 'Sign in',
  },
  'voice-chat': {
    title: 'Sign in to talk',
    body: 'Sign in to ask questions out loud and hear answers back.',
    cta: 'Sign in',
  },
  'ai-chat': {
    title: 'Sign in to ask',
    body: "Sign in to chat about what you're reading and get cited answers.",
    cta: 'Sign in',
  },
  sync: {
    title: 'Sign in to sync',
    body: 'Sign in to keep your library, highlights, and progress across devices.',
    cta: 'Sign in',
  },
  'ai-generic': {
    title: 'Sign in to continue',
    body: "Sign in to use Rishi's reading tools.",
    cta: 'Sign in',
  },
  'voice-input': {
    title: 'Sign in to talk',
    body: 'Sign in to ask questions out loud and hear answers back.',
    cta: 'Sign in',
  },
}
```

### 1.3 `packages/shared/src/auth-gating/shouldGate.ts`

```ts
import type { PremiumFeature } from './types'

export function shouldGate(
  user: { id: string } | null,
  _feature: PremiumFeature,
): boolean {
  return user === null
}
```

### 1.4 `packages/shared/src/auth-gating/index.ts`

```ts
export type { PremiumFeature, FeatureCopy } from './types'
export { FEATURE_COPY } from './featureCopy'
export { shouldGate } from './shouldGate'
```

### 1.5 `packages/shared/src/index.ts` — append

```ts
export * from "./auth-gating/index";
```

### 1.6 `packages/shared/package.json` — add export entry

After the existing `"./auth": "./src/auth/index.ts",` entry:
```json
"./auth-gating": "./src/auth-gating/index.ts"
```

---

## 2. Electron rewire (NO BEHAVIOR CHANGE)

### 2.1 `apps/rishi-electron/src/renderer/src/components/auth/features.ts`

Replace entire file with shim that re-exports shared types and supplements with electron-only icon + bullets:

```ts
import { Volume2, MessageSquare, Mic, Sparkles, type LucideIcon } from 'lucide-react'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { FEATURE_COPY } from '@rishi/shared/auth-gating'

export type { PremiumFeature }

export interface PremiumFeatureConfig {
  icon: LucideIcon
  title: string
  description: string
  bullets: string[]
}

export const PREMIUM_FEATURES: Record<PremiumFeature, PremiumFeatureConfig> = {
  tts: {
    icon: Volume2,
    title: FEATURE_COPY.tts.title,
    description: FEATURE_COPY.tts.body,
    bullets: ['Natural, expressive voices', 'Reads EPUB, PDF, and MOBI', 'Remembers your spot across devices'],
  },
  'ai-chat': {
    icon: MessageSquare,
    title: FEATURE_COPY['ai-chat'].title,
    description: FEATURE_COPY['ai-chat'].body,
    bullets: ["Cites passages from the book you're reading", 'Works across your entire library', 'Remembers context within a conversation'],
  },
  'voice-chat': {
    icon: Mic,
    title: FEATURE_COPY['voice-chat'].title,
    description: FEATURE_COPY['voice-chat'].body,
    bullets: ['Natural speech recognition', 'Paired with AI book chat'],
  },
  'voice-input': {
    icon: Mic,
    title: FEATURE_COPY['voice-input'].title,
    description: FEATURE_COPY['voice-input'].body,
    bullets: ['Natural speech recognition', 'Paired with AI book chat'],
  },
  sync: {
    icon: Sparkles,
    title: FEATURE_COPY.sync.title,
    description: FEATURE_COPY.sync.body,
    bullets: [],
  },
  'ai-generic': {
    icon: Sparkles,
    title: FEATURE_COPY['ai-generic'].title,
    description: FEATURE_COPY['ai-generic'].body,
    bullets: [],
  },
}
```

### 2.2 `useRequireAuth.tsx` — zero changes

Imports `PremiumFeature` from `'@/components/auth/features'` which re-exports from shared.

### 2.3 `PremiumFeatureDialog.tsx` — zero changes

Reads `config.description` which is now sourced from `FEATURE_COPY.body`.

### 2.4 Call site renames

| File | Line | Before | After |
|---|---|---|---|
| `hooks/reader/useCommonMenuHandlers.ts` | 62 | `'chat'` | `'ai-chat'` |
| `components/chat/VoiceChatLauncher.tsx` | 31 | `'voice-input'` | `'voice-chat'` |
| `components/pdf/components/pdf.tsx` | 434 | `'chat'` | `'ai-chat'` |

`useCommonMenuHandlers.ts:66` stays `'voice-input'` (chat-panel mic path).
`useCommonMenuHandlers.ts:6` optional type tightening: `type RequireAuth = (feature: import('@rishi/shared/auth-gating').PremiumFeature, action: () => void) => void`

---

## 3. Mobile new files

### 3.1 `apps/mobile/components/auth/useRequireAuth.ts`

```ts
import { useCallback } from 'react'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/lib/stores/authStore'

export function useRequireAuth(feature: PremiumFeature): (action: () => void) => void {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)
  const openPremiumGate = useAuthStore((s) => s.openPremiumGate)

  return useCallback(
    (action) => {
      if (!authHydrated || isAuthenticated) {
        action()
      } else {
        openPremiumGate(feature)
      }
    },
    [authHydrated, isAuthenticated, openPremiumGate, feature],
  )
}
```

### 3.2 `apps/mobile/components/auth/PremiumFeatureSheet.tsx`

No props. Fully controlled by `useAuthStore`.

```ts
export function PremiumFeatureSheet(): React.JSX.Element | null
```

Dependencies:
- `@gorhom/bottom-sheet` — `BottomSheet`, `BottomSheetView`, `BottomSheetBackdrop`
- `@expo/vector-icons/Ionicons`
- `expo-haptics`
- `react-native-reanimated` — shake animation
- `react-native-safe-area-context`
- `@rishi/shared/auth-gating` — `FEATURE_COPY`
- `@/lib/stores/authStore`
- `@/lib/auth` — `signIn`

Icon map (module scope):
```ts
const FEATURE_ICONS: Record<PremiumFeature, string> = {
  tts: 'headset-outline',
  'voice-chat': 'mic-outline',
  'voice-input': 'mic-outline',
  'ai-chat': 'chatbubble-ellipses-outline',
  sync: 'cloud-outline',
  'ai-generic': 'sparkles-outline',
}
```

CTA logic:
```ts
const ctaLabel = Platform.OS === 'ios' ? 'Continue with Apple' : 'Continue with Google'
const provider = Platform.OS === 'ios' ? 'apple' : 'google'
```

Snap: `enableDynamicSizing` with `index={-1}` initial.
Haptics: Soft on open, selection on press, Success on auth success, Error on auth fail.
VoiceOver: setAccessibilityFocus on title after ~350ms.
Error filter: skip msgs matching `/cancel|dismiss/i`.

---

## 4. Mobile modified files

### 4.1 `apps/mobile/lib/stores/authStore.ts`

Add import:
```ts
import type { PremiumFeature } from '@rishi/shared/auth-gating'
```

Add to `AuthState` interface:
```ts
premiumGateOpen: boolean
premiumGateFeature: PremiumFeature | null
openPremiumGate: (feature: PremiumFeature) => void
closePremiumGate: () => void
```

Initial state:
```ts
premiumGateOpen: false,
premiumGateFeature: null,
```

Actions:
```ts
openPremiumGate: (feature) => set({ premiumGateOpen: true, premiumGateFeature: feature }),
closePremiumGate: () => set({ premiumGateOpen: false, premiumGateFeature: null }),
```

### 4.2 `apps/mobile/app/_layout.tsx`

GestureHandlerRootView already wraps both branches (lines 203, 214). Only add:
```ts
import { PremiumFeatureSheet } from '@/components/auth/PremiumFeatureSheet'
```

Mount inside both branches after `<RagExtractorHost />`:
```tsx
<PremiumFeatureSheet />
```

### 4.3 `apps/mobile/components/TTSControls.tsx`

```ts
import { useRequireAuth } from '@/components/auth/useRequireAuth'
// inside component:
const requireTTS = useRequireAuth('tts')

const handlePlay = () => {
  if (isPlaying) send({ type: 'PAUSE' })
  else if (isPaused) send({ type: 'RESUME' })
  else requireTTS(() => send({ type: 'PLAY' }))
}
```

### 4.4 `apps/mobile/app/reader/[id].tsx`

Add hook calls inside `ReaderContent`:
```ts
const requireTTS = useRequireAuth('tts')
const requireAIChat = useRequireAuth('ai-chat')
const requireVoiceChat = useRequireAuth('voice-chat')
```

`handleToggleTTS`:
```ts
const handleToggleTTS = useCallback(() => {
  const sendFn = usePlayerStore.getState().send
  if (!sendFn) return
  if (ttsActive) { sendFn({ type: 'STOP' }); return }
  requireTTS(async () => {
    try {
      const seeded = await seedPlayerParagraphsFromChunks(book.id, book.filePath, book.format)
      if (!seeded.seeded) return
      sendFn({ type: 'PLAY' })
    } catch (err) { console.warn('[reader-tts] seed failed:', err) }
  })
}, [book.id, book.filePath, book.format, ttsActive, requireTTS])
```

`onChatPress`:
```ts
onChatPress={() => requireAIChat(() => router.push(`/chat/${book.id}`))}
```

`onRealtimePress`:
```ts
onRealtimePress={() => {
  if (realtimeActive) toggleRealtime()
  else requireVoiceChat(toggleRealtime)
}}
```

### 4.5 `apps/mobile/app/chat/[bookId].tsx`

```ts
import { useRequireAuth } from '@/components/auth/useRequireAuth'
const requireVoiceInput = useRequireAuth('voice-input')
const requireAIChat = useRequireAuth('ai-chat')
```

`handleMicPress`:
```ts
const handleMicPress = useCallback(() => {
  if (voice.isRecording) {
    void voice.stopAndTranscribe().then((t) => { if (t) setVoiceText(t) })
  } else {
    requireVoiceInput(() => {
      setVoiceText(null)
      void voice.startRecording()
    })
  }
}, [voice, requireVoiceInput])
```

`<ChatInput onSend={...}>`:
```tsx
<ChatInput onSend={(text) => requireAIChat(() => void handleSend(text))} ... />
```

### 4.6 `apps/mobile/app/(tabs)/chat.tsx`

```ts
import { useRequireAuth } from '@/components/auth/useRequireAuth'
const requireAIChat = useRequireAuth('ai-chat')
```

Wrap new conversation button:
```tsx
onPress={() => requireAIChat(handleNewConversation)}
```

---

## 5. Root layout

GestureHandlerRootView already at root (lines 203, 214 of `_layout.tsx`). Only addition: `<PremiumFeatureSheet />` in both branches.

---

## 6. Test surface

Mobile tests MUST live under `apps/mobile/__tests__/` (jest.config.js `roots`).

### Shared (vitest)
- `packages/shared/src/auth-gating/__tests__/should-gate.test.ts`
  - `shouldGate(null, f)` returns true for all features
  - `shouldGate({ id: 'x' }, f)` returns false for all features
- `packages/shared/src/auth-gating/__tests__/feature-copy.test.ts`
  - Every PremiumFeature key has a non-empty `title`, `body`, `cta`
  - All titles start with `'Sign in to '`
  - All bodies end with `'.'`
  - No body contains `' AI '` (keep copy plain)

### Mobile (jest)
- `apps/mobile/__tests__/hooks/useRequireAuth.test.ts`
  - Authenticated: runs action immediately
  - Unauthenticated + hydrated: calls `openPremiumGate(feature)`, does not run action
  - Not yet hydrated: optimistically runs action
  - Returned function is stable across re-renders
- `apps/mobile/__tests__/components/auth/PremiumFeatureSheet.test.tsx`
  - Renders null when `premiumGateOpen: false`
  - Renders title from `FEATURE_COPY` when open
  - CTA label is `'Continue with Apple'` on iOS, `'Continue with Google'` on Android
  - "Not now" button calls `closePremiumGate`
  - During `isAuthenticating`: CTA shows ActivityIndicator
  - On non-cancel error: error row visible with `"Couldn't sign in. Try again."`

### Electron (vitest)
- `apps/rishi-electron/src/renderer/src/components/auth/__tests__/PremiumFeatureDialog.test.tsx`
  - title for `'tts'` matches `FEATURE_COPY.tts.title`
  - description for `'ai-chat'` matches `FEATURE_COPY['ai-chat'].body`
  - bullets still render for `'tts'`
  - "Maybe later" closes dialog
  - "Sign in" calls `openSignIn`

---

## 7. Build order

```
1-6.   Create packages/shared/src/auth-gating/{types,featureCopy,shouldGate,index}.ts + index.ts export + package.json exports
       VERIFY: pnpm -C packages/shared typecheck
7-8.   Create shared tests (red)
       RUN: pnpm -C packages/shared test (expect failures only if impl missing — should pass since impl is in same commit)
       COMMIT: "feat(shared): auth-gating package — PremiumFeature, FEATURE_COPY, shouldGate"

10-13. Replace electron features.ts + 3 call-site renames
       VERIFY: pnpm -C apps/rishi-electron typecheck && test
       COMMIT: "refactor(electron): wire features.ts to shared auth-gating, rename feature keys"

14-15. Mobile tests (red)
       COMMIT: "test(mobile): failing tests for useRequireAuth + PremiumFeatureSheet [red]"

16-18. authStore additions + useRequireAuth + PremiumFeatureSheet
       VERIFY: pnpm -C apps/mobile test (green)
       COMMIT: "feat(mobile): useRequireAuth hook + PremiumFeatureSheet component [green]"

19-23. Wire 7 call sites + _layout.tsx mount
       VERIFY: pnpm -C apps/mobile test
       COMMIT: "feat(mobile): wire premium gate to all 7 call sites"

24.    Electron PremiumFeatureDialog test
       COMMIT: "test(electron): PremiumFeatureDialog consumes shared FEATURE_COPY [green]"

25.    Final verification — all three suites green
```

---

## 8. Risks verified

- **R1 (feature rename)** — confirmed; 4 line-level edits in electron mapped (§2.4).
- **R2 (no auto-resume)** — accepted; both platforms drop pending action on dismiss.
- **R3 (icon)** — confirmed; FeatureCopy omits icon; electron uses Lucide locally, mobile uses Ionicons.
- **R4 (openSignIn differs)** — resolved; PremiumFeatureSheet calls `signIn()` directly via expo-web-browser.
- **R5 (authHydrated false)** — resolved in hook; when `!authHydrated`, optimistically runs action.
- **R6 (GestureHandlerRootView)** — **ALREADY RESOLVED** by inspection; both branches of `_layout.tsx` already wrap with GHRV.
- **R7 (jest roots)** — discovered; all mobile tests go under `__tests__/`.
- **R8 (filename convention)** — resolved; shared uses camelCase (`featureCopy.ts`, `shouldGate.ts`).
- **R9 (TTSControls no gate)** — confirmed; §4.3 covers.
- **R10 (nested GHRV in reader)** — harmless; out of scope.

---

## 9. PremiumFeatureSheet — full component skeleton (for coder)

```tsx
import React, { useCallback, useEffect, useRef, useState } from 'react'
import { View, Text, Pressable, ActivityIndicator, Platform, useColorScheme, AccessibilityInfo } from 'react-native'
import BottomSheet, { BottomSheetBackdrop, BottomSheetView, type BottomSheetBackdropProps } from '@gorhom/bottom-sheet'
import Ionicons from '@expo/vector-icons/Ionicons'
import * as Haptics from 'expo-haptics'
import Animated, { useSharedValue, useAnimatedStyle, withSequence, withTiming } from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { FEATURE_COPY, type PremiumFeature } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/lib/stores/authStore'
import { signIn } from '@/lib/auth'

const FEATURE_ICONS: Record<PremiumFeature, keyof typeof Ionicons.glyphMap> = {
  tts: 'headset-outline',
  'voice-chat': 'mic-outline',
  'voice-input': 'mic-outline',
  'ai-chat': 'chatbubble-ellipses-outline',
  sync: 'cloud-outline',
  'ai-generic': 'sparkles-outline',
}

export function PremiumFeatureSheet(): React.JSX.Element | null {
  const open = useAuthStore((s) => s.premiumGateOpen)
  const feature = useAuthStore((s) => s.premiumGateFeature)
  const isAuthenticating = useAuthStore((s) => s.isAuthenticating)
  const closeGate = useAuthStore((s) => s.closePremiumGate)

  const sheetRef = useRef<BottomSheet>(null)
  const titleRef = useRef<Text>(null)
  const [error, setError] = useState<string | null>(null)
  const shakeX = useSharedValue(0)
  const shakeStyle = useAnimatedStyle(() => ({ transform: [{ translateX: shakeX.value }] }))
  const scheme = useColorScheme()
  const insets = useSafeAreaInsets()

  // Open/close via store flag
  useEffect(() => {
    if (open) {
      sheetRef.current?.expand()
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Soft)
      setError(null)
      const t = setTimeout(() => {
        if (titleRef.current) {
          AccessibilityInfo.setAccessibilityFocus(
            (titleRef.current as unknown as { _nativeTag?: number })._nativeTag ?? 0,
          )
        }
      }, 350)
      return () => clearTimeout(t)
    } else {
      sheetRef.current?.close()
    }
  }, [open])

  const handleSignIn = useCallback(async () => {
    Haptics.selectionAsync()
    setError(null)
    const provider = Platform.OS === 'ios' ? 'apple' : 'google'
    try {
      await signIn(provider)
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
      closeGate()
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      if (!/cancel|dismiss/i.test(msg)) {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
        setError("Couldn't sign in. Try again.")
        shakeX.value = withSequence(
          withTiming(6, { duration: 60 }),
          withTiming(-6, { duration: 60 }),
          withTiming(4, { duration: 60 }),
          withTiming(-4, { duration: 60 }),
          withTiming(0, { duration: 60 }),
        )
      }
    }
  }, [closeGate, shakeX])

  const handleDismiss = useCallback(() => {
    Haptics.selectionAsync()
    closeGate()
  }, [closeGate])

  const renderBackdrop = useCallback(
    (props: BottomSheetBackdropProps) => (
      <BottomSheetBackdrop {...props} appearsOnIndex={0} disappearsOnIndex={-1} pressBehavior="close" />
    ),
    [],
  )

  if (!feature) return null
  const copy = FEATURE_COPY[feature]
  const iconName = FEATURE_ICONS[feature]
  const ctaLabel = Platform.OS === 'ios' ? 'Continue with Apple' : 'Continue with Google'
  const isDark = scheme === 'dark'

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      enableDynamicSizing
      enablePanDownToClose
      onClose={closeGate}
      backdropComponent={renderBackdrop}
      handleIndicatorStyle={{ backgroundColor: isDark ? '#48484A' : '#C7C7CC' }}
      backgroundStyle={{ backgroundColor: isDark ? '#1C1C1E' : '#FFFFFF' }}
      accessibilityViewIsModal
    >
      <BottomSheetView style={{ paddingHorizontal: 24, paddingTop: 8, paddingBottom: insets.bottom + 24 }}>
        <View style={{ alignItems: 'center', marginTop: 16, marginBottom: 16 }}>
          <View
            style={{
              width: 56, height: 56, borderRadius: 28, alignItems: 'center', justifyContent: 'center',
              backgroundColor: isDark ? 'rgba(10,126,164,0.18)' : 'rgba(10,126,164,0.10)',
            }}
          >
            <Ionicons name={iconName} size={28} color="#0a7ea4" />
          </View>
        </View>
        <Text
          ref={titleRef}
          accessibilityRole="header"
          style={{ fontSize: 22, fontWeight: '600', textAlign: 'center', color: isDark ? '#FFF' : '#000', marginBottom: 8 }}
        >
          {copy.title}
        </Text>
        <Text
          style={{
            fontSize: 16, lineHeight: 22, textAlign: 'center',
            color: isDark ? '#EBEBF5' : '#3C3C43', marginBottom: 24, opacity: 0.85,
          }}
        >
          {copy.body}
        </Text>
        <Animated.View style={shakeStyle}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={ctaLabel}
            onPress={handleSignIn}
            disabled={isAuthenticating}
            style={({ pressed }) => ({
              height: 50, borderRadius: 12, alignItems: 'center', justifyContent: 'center',
              backgroundColor: '#0a7ea4', opacity: pressed ? 0.85 : 1, marginBottom: 8,
            })}
          >
            {isAuthenticating ? (
              <ActivityIndicator color="#FFF" />
            ) : (
              <Text style={{ color: '#FFF', fontSize: 17, fontWeight: '600' }}>{ctaLabel}</Text>
            )}
          </Pressable>
        </Animated.View>
        {error ? (
          <Text style={{ color: '#FF3B30', fontSize: 13, textAlign: 'center', marginTop: 4, marginBottom: 4 }}>
            {error}
          </Text>
        ) : null}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Not now"
          onPress={handleDismiss}
          style={{ height: 44, alignItems: 'center', justifyContent: 'center' }}
        >
          <Text style={{ color: '#0a7ea4', fontSize: 17 }}>Not now</Text>
        </Pressable>
      </BottomSheetView>
    </BottomSheet>
  )
}
```

This skeleton may need minor adjustment for `signIn(provider)` signature in `lib/auth.ts` — coder verifies.
