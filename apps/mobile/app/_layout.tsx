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

import { useColorScheme } from '@/hooks/use-color-scheme'
import { useAuthStore } from '@/lib/stores/authStore'
import { initVectorExtension, ensureChunkTables } from '@/lib/rag/vector-store'
import { RagExtractorHost } from '@/components/RagExtractorHost'
import { handleIncomingFile, isFileUrl } from '@/lib/file-handler'

export const IS_E2E_TEST = process.env.EXPO_PUBLIC_E2E_TEST === 'true'

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

  // Run the MMKV hydration once at startup so child layouts know the
  // last-known welcomeSeen flag + persisted user id before they render.
  useEffect(() => {
    hydrateAuth()
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
        if (initialUrl && isFileUrl(initialUrl)) {
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

  if (IS_E2E_TEST) {
    return (
      <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
        <Slot />
        <RagExtractorHost />
        <StatusBar style="auto" />
      </ThemeProvider>
    )
  }

  return (
    <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <Slot />
      {/*
        Hidden host that drives pdfjs / djvu.js text extraction inside
        WebViews on demand. Mounted at root so import jobs can extract
        text regardless of which screen the user is on. See
        lib/rag/extractors/* + lib/rag/chunker.ts for the contract.
       */}
      <RagExtractorHost />
      <StatusBar style="auto" />
    </ThemeProvider>
  )
}

export default Sentry.wrap(RootLayout)
