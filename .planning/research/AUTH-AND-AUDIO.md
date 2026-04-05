# Research: Mobile Auth (Clerk) + Audio (TTS/STT) on React Native

**Domain:** Mobile reading app - authentication and audio subsystems
**Researched:** 2026-04-05
**Overall confidence:** HIGH (Clerk Expo), MEDIUM (Audio)

---

## 1. Clerk Expo SDK (`@clerk/expo`)

### Setup

**Confidence: HIGH** (verified with official Clerk docs)

Install:
```bash
npx expo install @clerk/expo expo-secure-store
```

Root layout (`app/_layout.tsx`) wraps everything in `ClerkProvider`:
```tsx
import { ClerkProvider } from '@clerk/expo'
import { tokenCache } from '@clerk/expo/token-cache'
import { Slot } from 'expo-router'

export default function RootLayout() {
  return (
    <ClerkProvider
      publishableKey={process.env.EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY!}
      tokenCache={tokenCache}
    >
      <Slot />
    </ClerkProvider>
  )
}
```

The `tokenCache` from `@clerk/expo/token-cache` uses `expo-secure-store` under the hood for encrypted token persistence. No manual SecureStore wiring needed.

### Expo Router Integration

Use route groups with auth guards:

- `app/(auth)/` -- sign-in/sign-up screens, redirect away if already signed in
- `app/(home)/` or `app/(tabs)/` -- protected screens, redirect to sign-in if not authenticated

Each group layout checks `useAuth()`:
```tsx
import { useAuth } from '@clerk/expo'
import { Redirect, Stack } from 'expo-router'

export default function ProtectedLayout() {
  const { isSignedIn, isLoaded } = useAuth()
  if (!isLoaded) return null
  if (!isSignedIn) return <Redirect href="/(auth)/sign-in" />
  return <Stack />
}
```

### Authentication Approach

**Recommendation: Use Clerk's pre-built sign-in/sign-up components** (`<SignIn />`, `<SignUp />`), not the native components (beta, requires dev builds with SwiftUI/Jetpack Compose). The pre-built web-based components work in Expo Go during development and are battle-tested.

If you want fully native UI later, Clerk also supports custom flows via `useSignIn()` and `useSignUp()` hooks where you build your own UI.

### Gotchas

1. **Native API must be enabled** -- In the Clerk Dashboard, go to Native Applications and ensure the Native API toggle is ON. Without this, token refresh will fail silently.

2. **Cannot run in Expo Go with native components** -- The native SwiftUI/Jetpack Compose components require a development build. The standard pre-built components work fine in Expo Go.

3. **Plugin registration** -- Add to `app.json` plugins array:
   ```json
   "plugins": ["expo-secure-store", "@clerk/expo"]
   ```

4. **Token refresh is automatic** -- `@clerk/expo` handles session token refresh transparently. You call `getToken()` and it returns a valid token, refreshing if needed.

5. **`treatPendingAsSignedOut`** -- If using native components, pass `{ treatPendingAsSignedOut: false }` to `useAuth()` to avoid flicker during pending session tasks. Not needed for standard components.

---

## 2. Token Exchange: Clerk Session Token to Worker JWT

**Confidence: HIGH** (verified against existing Worker code)

### How It Works

The existing `/api/auth/exchange` endpoint on the Worker already does exactly what the mobile app needs:

1. Receives a request with a Clerk session token in the `Authorization: Bearer <clerk_session_token>` header
2. The `clerkMiddleware()` on the Worker validates the Clerk token and extracts `userId`
3. The endpoint mints a 7-day Worker JWT (`{ sub: userId, iat, exp }`) signed with `JWT_SECRET`
4. Returns `{ token, expiresAt, user }`

### Mobile Implementation

```tsx
import { useAuth } from '@clerk/expo'

async function exchangeForWorkerToken() {
  const { getToken } = useAuth()
  const clerkToken = await getToken()

  const response = await fetch('https://your-worker.workers.dev/api/auth/exchange', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${clerkToken}`,
      'Content-Type': 'application/json',
    },
  })

  const { token, expiresAt, user } = await response.json()
  // Store `token` in expo-secure-store for subsequent API calls
  // Use `token` as Bearer token for all requireWorkerAuth endpoints
}
```

### CORS Update Required

The Worker's CORS config currently allows:
```ts
origin: ["https://rishi.fidexa.org", "tauri://localhost", "http://tauri.localhost"]
```

**Mobile apps do NOT send an Origin header** for fetch requests from React Native. The CORS middleware may need adjustment. Two options:

1. **Preferred:** React Native `fetch` does not set an Origin header by default, so CORS is typically not an issue for native mobile requests (CORS is a browser-enforced policy). Test this -- it likely just works.
2. **Fallback:** If the Worker's CORS middleware rejects requests without a recognized Origin, add a wildcard or a specific mobile identifier.

### Token Storage on Mobile

Store the Worker JWT in `expo-secure-store`:
```tsx
import * as SecureStore from 'expo-secure-store'

await SecureStore.setItemAsync('worker_jwt', token)
const jwt = await SecureStore.getItemAsync('worker_jwt')
```

### Token Lifecycle

- Clerk session token: short-lived (auto-refreshed by SDK, ~60s)
- Worker JWT: 7 days
- On app launch: check if Worker JWT exists and is not expired. If expired, call `getToken()` from Clerk and re-exchange.

---

## 3. Audio Playback (TTS)

**Confidence: MEDIUM**

### The Problem

The Worker's `/api/audio/speech` endpoint proxies OpenAI TTS and returns raw audio data (the OpenAI SDK response is returned directly). The mobile app needs to play this audio.

### Recommendation: `expo-audio` (the new API)

**Use `expo-audio`, NOT `expo-av`.** The `expo-audio` module is Expo's newer, dedicated audio library with a cleaner hook-based API. `expo-av` is the older combined audio/video library that still works but is being superseded.

**Do NOT use `react-native-track-player`** unless you need background playback with lock screen controls. It adds significant native complexity and conflicts with expo-av/expo-audio. For playing TTS responses (short audio clips, not music playlists), it is overkill.

### Implementation Approach

Since the TTS endpoint returns audio data (not a URL), you need to:

1. Fetch the audio from the Worker endpoint
2. Write it to a temporary file (or use a blob URL)
3. Play it with `expo-audio`

```tsx
import { useAudioPlayer } from 'expo-audio'
import * as FileSystem from 'expo-file-system'

// Fetch TTS audio and save to temp file
async function fetchTTS(text: string, workerJwt: string): Promise<string> {
  const response = await fetch('https://your-worker.workers.dev/api/audio/speech', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${workerJwt}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ model: 'tts-1', input: text, voice: 'alloy' }),
  })

  const blob = await response.blob()
  const reader = new FileReader()
  // Convert to base64 and save to file
  const fileUri = FileSystem.cacheDirectory + 'tts_audio.mp3'
  // Use FileSystem.writeAsStringAsync with base64 encoding
  return fileUri
}

// Then play with useAudioPlayer hook
const player = useAudioPlayer(fileUri)
player.play()
```

**Alternative approach:** If the Worker endpoint is modified to return a streaming URL or the response can be played directly, `useAudioPlayer` accepts URLs directly:
```tsx
const player = useAudioPlayer('https://your-worker.workers.dev/api/audio/speech?...')
```

### Key Considerations

- **expo-audio** requires `expo install expo-audio` (separate from expo-av)
- Background playback on Android stops after ~3 minutes without lock screen controls (OS limitation). Not an issue for TTS clips.
- Audio stops when headphones/Bluetooth disconnect (expected behavior)
- `downloadFirst: true` option pre-downloads before playback (good for TTS)

### Install

```bash
npx expo install expo-audio expo-file-system
```

---

## 4. Audio Recording (STT)

**Confidence: MEDIUM**

### The Problem

The app needs to capture speech from the microphone and send it to Deepgram (via the Worker or directly) for transcription.

### Two Approaches

#### Approach A: Record-then-Send (Simpler)

Record a complete audio clip, then upload it for transcription.

**Use `expo-audio` recording:**
```tsx
import { useAudioRecorder, RecordingPresets } from 'expo-audio'

const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY)

// Start recording
await recorder.prepareToRecordAsync()
recorder.record()

// Stop and get URI
await recorder.stop()
const audioUri = recorder.uri // local file path
// Upload this file to Worker/Deepgram for transcription
```

**Pros:** Simple, works with expo-audio out of the box, no extra dependencies.
**Cons:** User must finish speaking before transcription begins. No real-time feedback.

#### Approach B: Stream Audio Chunks (Real-time)

Stream audio data in real-time to Deepgram's WebSocket API for live transcription.

**Recommendation: `@siteed/expo-audio-studio`** (formerly `@siteed/expo-audio-stream`)

This is the most mature Expo-native library for real-time audio streaming. It provides:
- Dual audio streams (raw PCM + compressed)
- Configurable sample rates (16kHz ideal for speech recognition)
- Real-time data events with audio chunks
- iOS, Android, and web support

**Alternative: `react-native-live-audio-stream`** -- simpler, emits base64-encoded PCM chunks via events. Less maintained but proven. Requires a dev build (native module).

**Alternative: `expo-speech-recognition`** -- wraps the native OS speech recognition APIs (Apple Speech, Google Speech). On-device, no server needed. BUT: less control over the raw audio, limited language models, and you lose the ability to use Deepgram's superior models.

### Recommended Path

**Start with Approach A (record-then-send)** using `expo-audio`. It is simpler, has no extra dependencies, and works for MVP. The user presses a button, speaks, releases, and the audio is sent to the Worker for Deepgram transcription.

**Upgrade to Approach B later** if real-time streaming transcription is needed. At that point, evaluate `@siteed/expo-audio-studio` for streaming chunks over a WebSocket to Deepgram.

### Deepgram Integration

The existing Worker does not have a Deepgram transcription endpoint (only has `DEEPGRAM_KEY` in bindings). You will need to either:

1. **Add a Worker endpoint** that accepts audio and forwards to Deepgram REST API
2. **Connect directly from mobile to Deepgram** using WebSocket (requires exposing API key or proxying through Worker)
3. **Use the Worker to mint a Deepgram temporary key** that the mobile app uses for WebSocket connection

Option 1 is simplest for MVP. Option 3 is best for real-time streaming.

### Install (MVP)

```bash
npx expo install expo-audio
```

No additional packages needed for record-then-send approach.

---

## 5. Current State of `apps/mobile/`

**Confidence: HIGH** (directly inspected)

### Assessment

The existing mobile app is a **fresh Expo SDK 54 scaffold** with minimal customization. It is the default `create-expo-app` template with NativeWind added.

| Aspect | State |
|--------|-------|
| Expo SDK | 54 (current) |
| React Native | 0.81.5 (current) |
| Router | expo-router ~6.0.23 |
| Styling | NativeWind 4.2.1 + Tailwind 3.4.19 |
| New Architecture | Enabled (`newArchEnabled: true`) |
| React Compiler | Enabled (`reactCompiler: true`) |
| Typed Routes | Enabled |
| URL Scheme | `rishimobile` |
| Auth | None |
| Audio | None |
| Custom code | Nearly zero -- default tabs (Home, Explore), default modal |

### Verdict: Build on it, do NOT start fresh

The scaffold is clean, current, and has the right foundation:
- Expo SDK 54 with New Architecture
- expo-router 6 already configured
- NativeWind for Tailwind-style styling
- TypeScript strict mode
- URL scheme `rishimobile` already registered (useful for deep links)

The default tab screens and components should be replaced, but the project structure, config, and dependencies are solid.

### Required Changes

1. **Add ClerkProvider** to `app/_layout.tsx`
2. **Restructure routes** to `(auth)` and `(tabs)` groups
3. **Remove default explore tab content**, replace with app-specific screens
4. **Add expo-secure-store and @clerk/expo** to dependencies
5. **Add EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY** to .env
6. **Add expo-secure-store and @clerk/expo** to app.json plugins

---

## 6. Worker CORS and Mobile Compatibility

**Confidence: HIGH**

React Native's `fetch` does not enforce CORS (it is a browser security feature). The mobile app will send requests directly to the Worker without Origin headers, so the Worker's CORS middleware should pass them through. However, the `clerkMiddleware()` on all routes means the Clerk session token must be valid.

The auth flow is:
1. User signs in via Clerk in the mobile app (Clerk SDK handles everything)
2. Mobile app calls `getToken()` to get Clerk session token
3. Mobile app calls `POST /api/auth/exchange` with Clerk token
4. Worker returns Worker JWT
5. Mobile app stores Worker JWT and uses it for all subsequent API calls

This is **much simpler than the Tauri flow** because Clerk's React Native SDK manages the session natively -- no browser redirect, no state parameter, no deep link callback needed.

---

## Summary of Recommendations

| Area | Recommendation | Package | Confidence |
|------|---------------|---------|------------|
| Auth SDK | `@clerk/expo` with `expo-secure-store` | `@clerk/expo` | HIGH |
| Auth flow | `useAuth().getToken()` then exchange at `/api/auth/exchange` | -- | HIGH |
| Token storage | `expo-secure-store` for Worker JWT | `expo-secure-store` | HIGH |
| TTS playback | `expo-audio` with `useAudioPlayer` | `expo-audio` | MEDIUM |
| STT recording (MVP) | `expo-audio` with `useAudioRecorder`, upload file | `expo-audio` | MEDIUM |
| STT streaming (later) | `@siteed/expo-audio-studio` for real-time chunks | `@siteed/expo-audio-studio` | LOW |
| Existing scaffold | Build on it, do not start fresh | -- | HIGH |

### Packages to Install

```bash
# Auth
npx expo install @clerk/expo expo-secure-store

# Audio (playback + recording)
npx expo install expo-audio

# File system (for TTS temp files)
npx expo install expo-file-system
```

### app.json Plugin Changes

```json
"plugins": [
  "expo-router",
  "expo-secure-store",
  "@clerk/expo",
  ["expo-splash-screen", { ... }]
]
```

---

## Open Questions / Gaps

1. **TTS response format** -- Need to verify exactly what format `/api/audio/speech` returns (MP3? raw PCM?). OpenAI TTS defaults to MP3, which `expo-audio` plays natively.

2. **Deepgram Worker endpoint** -- No STT endpoint exists on the Worker yet. Need to build one (or decide on direct WebSocket from mobile).

3. **expo-audio stability** -- `expo-audio` is newer than `expo-av`. If issues arise, `expo-av` is the proven fallback with nearly identical capabilities.

4. **Background audio** -- If users want TTS to continue playing while the app is backgrounded, additional native config is needed (iOS: Background Modes audio capability; Android: foreground service or lock screen controls).

5. **`@siteed/expo-audio-studio` Expo 54 compat** -- Not explicitly confirmed. Test before committing to it for real-time streaming.

---

## Sources

- [Clerk Expo Quickstart](https://clerk.com/docs/expo/getting-started/quickstart)
- [Clerk useAuth() Expo Reference](https://clerk.com/docs/expo/reference/hooks/use-auth)
- [Clerk Making Authenticated Requests](https://clerk.com/docs/guides/development/making-requests)
- [Clerk Expo SDK Reference](https://clerk.com/docs/reference/expo/overview)
- [Expo Audio Documentation](https://docs.expo.dev/versions/latest/sdk/audio/)
- [Expo AV Documentation](https://docs.expo.dev/versions/latest/sdk/av/)
- [@siteed/expo-audio-studio (GitHub)](https://github.com/deeeed/expo-audio-stream)
- [react-native-live-audio-stream (GitHub)](https://github.com/xiqi/react-native-live-audio-stream)
- [expo-speech-recognition (GitHub)](https://github.com/jamsch/expo-speech-recognition)
- [Deepgram React Native Integration](https://denieler.com/blog/deepgram-integration-react-native)
- [Expo Real-Time Audio Processing Blog](https://expo.dev/blog/real-time-audio-processing-with-expo-and-native-code)
