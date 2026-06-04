import {
  DarkTheme,
  DefaultTheme,
  ThemeProvider,
} from '@react-navigation/native'
import { Slot } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import * as Linking from 'expo-linking'
import * as Sentry from '@sentry/react-native'
import { useEffect } from 'react'
import { initExecutorch } from 'react-native-executorch'
import { ExpoResourceFetcher } from 'react-native-executorch-expo-resource-fetcher'
import 'react-native-reanimated'
import '../global.css'
import { GestureHandlerRootView } from 'react-native-gesture-handler'

import { useColorScheme } from '@/hooks/use-color-scheme'
import { useAuthStore } from '@/lib/stores/authStore'
import { initVectorExtension, ensureChunkTables } from '@/lib/rag/vector-store'
import { RagExtractorHost } from '@/components/RagExtractorHost'
import { PremiumFeatureSheet } from '@/components/auth/PremiumFeatureSheet'
import { BillingInactiveModal } from '@/components/billing/BillingInactiveModal'
import { handleIncomingFile, isFileUrl } from '@/lib/file-handler'
import { runStartupWiring } from '@/lib/voice-chat/startup-wiring'

export const IS_E2E_TEST = process.env.EXPO_PUBLIC_E2E_TEST === 'true'

/**
 * Dispatch an `rishimobile://e2e/<action>?<query>` deep link to the
 * appropriate test-fixture seeder. Only invoked from the URL listener
 * below, and only when `IS_E2E_TEST` is true.
 *
 * Actions:
 *   - `seed-book?format=epub|pdf|mobi|djvu` → seeds a single book
 *     from the matching fixture file that the Detox host pushed
 *     into the app's Documents directory.
 *   - `seed-chat?count=N` → seeds N chat conversations (no book file
 *     required; uses the in-memory chat fixture).
 *   - `clear-chat` → wipes the deterministic chat seed rows.
 *   - `set-session?token=<bearer>&user-id=<id>&email=<addr>` → hydrates
 *     the auth store with a real Better-Auth session token so the
 *     cross-platform sync test (apps/mobile/e2e/cross-platform-sync.test.ts)
 *     can sign the app in as a worker-created test user without going
 *     through the in-app browser OAuth dance. Persists the bearer to
 *     expo-secure-store so `getSessionToken()` returns it after restart.
 *     Gated on IS_E2E_TEST (no-op in production builds — but production
 *     builds also strip the seed-link branch above).
 */
async function handleE2ESeedLink(url: string): Promise<void> {
  const parsed = Linking.parse(url)
  // Action lives in the `e2e-action` query param so we can use a root
  // URL path (`/`) that expo-router successfully routes — keeping the
  // user on the Library tab while we run the side-effect.
  const params = parsed.queryParams ?? {}
  const action = String(params['e2e-action'] ?? '')

  if (action === 'set-session') {
    // Imported eagerly here (not lazily) to avoid a flicker where the
    // tab-layout's auth-guard redirects to /sign-in before the bridge
    // finishes hydrating the store.
    const token = String(params.token ?? '')
    const userId = String(params['user-id'] ?? '')
    const email = params.email != null ? String(params.email) : null
    if (!token || !userId) {
      console.warn('[e2e-seed] set-session: missing token or user-id')
      return
    }
    const { setSessionForE2E } = await import('@/lib/auth')
    await setSessionForE2E({ token, userId, email })
    return
  }

  // Lazy import to keep the test-fixtures module out of the production
  // bundle's hot path. Metro still bundles it, but it's only evaluated
  // when an E2E seed link arrives.
  const seedModule = await import('@/lib/test-fixtures/seed')

  if (action === 'seed-book') {
    const format = String(params.format ?? '') as
      | 'epub'
      | 'pdf'
      | 'mobi'
      | 'azw3'
      | 'djvu'
    if (!['epub', 'pdf', 'mobi', 'azw3', 'djvu'].includes(format)) {
      console.warn(`[e2e-seed] unknown format: ${format}`)
      return
    }
    await seedModule.seedBookFromFixture(format)
    return
  }
  if (action === 'seed-chat') {
    const count = Number(params.count ?? 2) || 2
    seedModule.seedChatFixtures({ count })
    return
  }
  if (action === 'clear-chat') {
    seedModule.clearChatFixtures()
    return
  }
  console.warn(`[e2e-seed] unknown action: ${action}`)
}

Sentry.init({
  dsn: process.env.EXPO_PUBLIC_SENTRY_DSN ?? '',
  tracesSampleRate: 1.0,
  enableAutoSessionTracking: true,
  sessionTrackingIntervalMillis: 30000,
})

// Initialize ExecuTorch before any hook usage
initExecutorch({ resourceFetcher: ExpoResourceFetcher })

// Initialize sqlite-vec and ensure chunk tables exist
try {
  initVectorExtension()
  ensureChunkTables()
} catch (e) {
  console.warn('[vector-store] Failed to initialize:', e)
}

function RootLayout() {
  const colorScheme = useColorScheme()
  const hydrateAuth = useAuthStore((s) => s.hydrateAuth)

  // Run the cold-start hydration once at startup so child layouts know
  // the last-known welcomeSeen flag, persisted user id, AND secure-store
  // bearer before they render. `authHydrated` flips true at the end
  // regardless of result, so route guards in `(tabs)/_layout.tsx` un-block
  // even for users who land directly on `/(tabs)` without ever mounting
  // `/(auth)/_layout.tsx` (H1-04).
  useEffect(() => {
    void hydrateAuth()
      .catch((err: unknown) => {
        console.warn('[layout] hydrateAuth threw:', err)
      })
      .finally(() => {
        // T-P2.1 (WIRING-001) — wire the voice-chat service into the chat
        // store after auth hydration completes. Idempotent and auth-gated:
        // the wiring module subscribes to the auth store and calls
        // `setChatVoicePort` exactly once when a session becomes available.
        try {
          runStartupWiring()
        } catch (err) {
          console.warn('[layout] runStartupWiring threw:', err)
        }
      })
  }, [hydrateAuth])

  // The Better-Auth deep-link round-trip is driven by
  // `WebBrowser.openAuthSessionAsync` in `lib/auth.signIn()`, which already
  // resolves with the callback URL — we do NOT need to subscribe to
  // `Linking.addEventListener('url', …)` for that flow. We DO listen here
  // so cold-start deep links (app not running when the redirect fires)
  // can be observed by future features (e.g. share-into-Rishi).
  useEffect(() => {
    // Also handle the cold-start case: if the app was launched *by*
    // an Open-With share-sheet action (or via a deep link), the URL
    // arrives via `getInitialURL()` instead of an event.
    void (async () => {
      try {
        const initialUrl = await Linking.getInitialURL()
        if (!initialUrl) return
        if (IS_E2E_TEST && initialUrl.includes('e2e-action=')) {
          // Cold-launch via Detox `device.launchApp({ url })` lands the
          // E2E seed URL here. The hot-launch path (URL listener
          // below) handles the same URL the same way.
          await handleE2ESeedLink(initialUrl)
          return
        }
        if (isFileUrl(initialUrl)) {
          await handleIncomingFile(initialUrl)
        }
      } catch (err) {
        console.warn('[layout] failed to handle initial URL:', err)
      }
    })()

    const sub = Linking.addEventListener('url', ({ url }) => {
      if (url.startsWith('rishimobile://auth/callback')) {
        // No-op: openAuthSessionAsync handles in-flight callbacks. This
        // branch only fires for cold-start callbacks where the browser
        // was already closed — currently nothing else to do.
        return
      }
      if (IS_E2E_TEST && url.includes('e2e-action=')) {
        // E2E seed bridge — the Detox host pushes a fixture into the
        // app's Documents directory then opens a URL containing
        // `e2e-action=<name>` in the query string to trigger an in-app
        // import. We use a query-only URL (e.g. `rishimobile:///?e2e-action=seed-book&format=epub`)
        // because expo-router's deep-link router otherwise tries to
        // navigate to `/seed-book` and shows an Unmatched-Route page
        // before our Linking subscriber gets to consume the URL.
        //
        // Gated on IS_E2E_TEST so production builds never hit this
        // branch.
        void handleE2ESeedLink(url).catch((err: unknown) => {
          console.warn('[layout] E2E seed link failed:', err)
        })
        return
      }
      if (isFileUrl(url)) {
        // File-association entry-point (G27): user picked Rishi from
        // the iOS share sheet or Android intent picker. Fire-and-
        // forget — errors are logged inside the handler.
        void handleIncomingFile(url).catch((err: unknown) => {
          console.warn('[layout] handleIncomingFile threw:', err)
        })
      }
    })
    return () => {
      sub.remove()
    }
  }, [])

  // NB: GlobalMiniPlayer is intentionally NOT mounted here. It now lives
  // inside the Tabs subtree via `<Tabs screenLayout={…}>` in
  // `(tabs)/_layout.tsx` so it can (a) read the live tab-bar height via
  // `useBottomTabBarHeight()` and (b) automatically vanish on stack
  // routes outside the tabs group (/reader/[id], /chat/[bookId]).
  // Fixes P0-Q (49pt hardcode) + P0-R (chat-detail bleed-through).
  if (IS_E2E_TEST) {
    return (
      <GestureHandlerRootView style={{ flex: 1 }}>
        <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
          <Slot />
          <RagExtractorHost />
          <PremiumFeatureSheet />
          <BillingInactiveModal />
          <StatusBar style="auto" />
        </ThemeProvider>
      </GestureHandlerRootView>
    )
  }

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
        <Slot />
        {/*
          Hidden host that drives pdfjs / djvu.js text extraction inside
          WebViews on demand. Mounted at root so import jobs can extract
          text regardless of which screen the user is on. See
          lib/rag/extractors/* + lib/rag/chunker.ts for the contract.
         */}
        <RagExtractorHost />
        <PremiumFeatureSheet />
        <BillingInactiveModal />
        <StatusBar style="auto" />
      </ThemeProvider>
    </GestureHandlerRootView>
  )
}

export default Sentry.wrap(RootLayout)
