# Phase 11: Mobile Feature Parity - Research

**Researched:** 2026-04-06
**Domain:** OpenAI Realtime voice chat (React Native), AI guardrails, sync status UI, Sentry error tracking (Expo)
**Confidence:** MEDIUM

## Summary

Phase 11 brings four desktop features to the mobile app: (1) live voice conversations via OpenAI Realtime API, (2) AI guardrails/tripwire to keep conversations on-topic, (3) a sync status indicator showing synced/syncing/offline/failed states, and (4) Sentry crash and error reporting.

The highest-risk item is OpenAI Realtime on React Native. The desktop uses `@openai/agents` with `RealtimeSession` which internally handles WebRTC/audio in a browser context. This SDK does **not** support React Native (confirmed via GitHub issue #133). The solution is to use `react-native-webrtc` to create a raw WebRTC RTCPeerConnection against the OpenAI Realtime WebRTC endpoint directly, using the existing Worker `/api/realtime/client_secrets` endpoint for ephemeral key acquisition. The guardrails and tool-calling (bookContext) must be reimplemented as data channel message handlers since we cannot use the `@openai/agents` guardrail framework on mobile. The sync status indicator is straightforward -- the desktop pattern (listener-based state with status enum) can be adapted to the mobile sync engine. Sentry integration uses `@sentry/react-native` v8.x with Expo plugin support (SDK 50+).

**Primary recommendation:** Implement OpenAI Realtime voice chat using raw WebRTC via `react-native-webrtc` + data channel for events, port the guardrail logic as a server-side classification call, and integrate `@sentry/react-native` with the Expo plugin system.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PARITY-M01 | User can have live voice conversations with AI about their book (OpenAI Realtime API) | WebRTC approach via react-native-webrtc; ephemeral key from existing Worker endpoint; bookContext tool via data channel + local RAG pipeline |
| PARITY-M02 | AI responses are guarded against off-topic content with tripwire classification | Server-side guardrail agent call via Worker LLM completions endpoint (cannot use @openai/agents on RN) |
| PARITY-M03 | User can see sync status (synced, syncing, offline, failed) with last sync time | Extend mobile sync engine with status tracking and listener pattern; SyncStatusIndicator component with NativeWind |
| PARITY-M04 | Crashes and errors are reported to Sentry with session tracking | @sentry/react-native v8.x with Expo plugin; Sentry.wrap() root layout; same Sentry org as web/desktop |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| react-native-webrtc | 124.0.7 | WebRTC for OpenAI Realtime audio | Only mature WebRTC implementation for RN; required since @openai/agents doesn't support RN |
| @sentry/react-native | 8.7.0 | Error tracking and crash reporting | Official Sentry SDK for React Native; Expo plugin support since SDK 50 |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| expo-audio | ~1.1.1 | Already installed | Used by existing voice input; no new install needed |
| react-native-webview | 13.15.0 | Already installed | Not needed for this phase |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| react-native-webrtc | WebSocket raw approach | WebRTC is OpenAI's recommended approach for client-side; handles audio I/O natively |
| react-native-webrtc | @openai/agents fork (chollier/openai-agents-js) | Community fork exists but unmerged/unmaintained; raw WebRTC is more reliable |
| Server-side guardrail | Client-side classification | Server-side is simpler and reuses existing Worker infrastructure |

**Installation:**
```bash
cd apps/mobile
npx expo install react-native-webrtc @sentry/react-native
```

## Architecture Patterns

### Recommended Project Structure
```
apps/mobile/
  lib/
    realtime/
      session.ts          # WebRTC session management (connect, disconnect, events)
      guardrails.ts       # Tripwire classification via Worker LLM
      types.ts            # Realtime event types
    sync/
      engine.ts           # (existing) -- add status tracking
      triggers.ts         # (existing) -- already has foreground/periodic/write triggers
      status.ts           # NEW: SyncStatus type, listener registry, status state
  hooks/
    useRealtimeChat.ts    # Hook wrapping realtime session for React components
    useSyncStatus.ts      # Hook exposing sync status to UI
  components/
    RealtimeVoiceButton.tsx  # FAB or button to start/stop realtime voice chat
    SyncStatusIndicator.tsx  # Compact status pill for library/settings screen
```

### Pattern 1: WebRTC Realtime Session
**What:** Direct WebRTC peer connection to OpenAI Realtime API using ephemeral key from Worker
**When to use:** For PARITY-M01 (live voice conversations)
**Example:**
```typescript
// Source: OpenAI Realtime WebRTC docs + react-native-webrtc
import { RTCPeerConnection, mediaDevices } from 'react-native-webrtc';

async function createRealtimeSession(bookId: string): Promise<RealtimeSession> {
  // 1. Get ephemeral key from Worker
  const response = await apiClient('/api/realtime/client_secrets');
  const clientSecret = await response.text();

  // 2. Create peer connection
  const pc = new RTCPeerConnection();

  // 3. Set up data channel for events (tool calls, text, session config)
  const dc = pc.createDataChannel('oai-events');
  dc.onmessage = (e) => handleServerEvent(JSON.parse(e.data));

  // 4. Add local audio track (microphone)
  const stream = await mediaDevices.getUserMedia({ audio: true });
  stream.getTracks().forEach(track => pc.addTrack(track, stream));

  // 5. Create offer and send to OpenAI
  const offer = await pc.createOffer({});
  await pc.setLocalDescription(offer);

  const sdpResponse = await fetch('https://api.openai.com/v1/realtime/calls', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${clientSecret}`,
      'Content-Type': 'application/sdp',
    },
    body: offer.sdp,
  });
  const answerSdp = await sdpResponse.text();
  await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });

  // 6. Send session config with tools and instructions
  dc.onopen = () => {
    dc.send(JSON.stringify({
      type: 'session.update',
      session: {
        instructions: REALTIME_AGENT_INSTRUCTIONS,
        tools: [bookContextToolDef, endConversationToolDef],
      }
    }));
    // Trigger initial greeting
    dc.send(JSON.stringify({
      type: 'conversation.item.create',
      item: {
        type: 'message',
        role: 'user',
        content: [{ type: 'input_text', text: 'Please greet the user...' }],
      }
    }));
    dc.send(JSON.stringify({ type: 'response.create' }));
  };

  return { pc, dc, stream };
}
```

### Pattern 2: Sync Status Listener
**What:** Observable sync status with subscriber pattern (matches desktop sync-triggers.ts)
**When to use:** For PARITY-M03 (sync status indicator)
**Example:**
```typescript
// Source: Desktop apps/main/src/modules/sync-triggers.ts pattern
import { AppState, type AppStateStatus } from 'react-native';
import NetInfo from '@react-native-community/netinfo'; // or use fetch-based check

export type SyncStatus = 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline';
type Listener = (status: SyncStatus, lastSyncAt: number | null) => void;

let status: SyncStatus = 'not-synced';
let lastSyncAt: number | null = null;
const listeners = new Set<Listener>();

export function onSyncStatusChange(listener: Listener): () => void {
  listeners.add(listener);
  listener(status, lastSyncAt);
  return () => listeners.delete(listener);
}

// Called from sync engine before/after sync
export function setSyncStatus(newStatus: SyncStatus) {
  status = newStatus;
  if (newStatus === 'synced') lastSyncAt = Date.now();
  listeners.forEach(l => l(status, lastSyncAt));
}
```

### Pattern 3: Server-Side Guardrail via Worker
**What:** Classify AI output through existing Worker LLM completions endpoint
**When to use:** For PARITY-M02 (tripwire for off-topic content)
**Example:**
```typescript
// Since @openai/agents guardrail framework doesn't work on RN,
// we classify via the Worker's existing /api/text/completions endpoint
async function checkGuardrail(agentOutput: string): Promise<boolean> {
  const response = await apiClient('/api/text/completions', {
    method: 'POST',
    body: JSON.stringify({
      input: [
        { role: 'system', content: GUARDRAIL_SYSTEM_PROMPT },
        { role: 'user', content: agentOutput },
      ],
    }),
  });
  const result = JSON.parse(await response.json());
  return !(result.isRelevantToBook || result.isSmallTalk);
}
```

### Anti-Patterns to Avoid
- **Using @openai/agents on React Native:** Does not work; depends on Node.js APIs. Use raw WebRTC instead.
- **Exposing OpenAI API key to mobile client:** Always use ephemeral keys via the Worker `/api/realtime/client_secrets` endpoint.
- **Polling for sync status:** Use the listener/subscriber pattern, not setInterval polling from UI components.
- **Running guardrail classification on-device:** The classification agent needs a capable LLM; route through Worker.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WebRTC peer connection | Custom WebSocket audio streaming | react-native-webrtc + OpenAI WebRTC endpoint | WebRTC handles codec negotiation, NAT traversal, audio I/O natively |
| Crash reporting | Custom error boundary + logging | @sentry/react-native | Session tracking, native crash capture, source maps, breadcrumbs |
| Network connectivity detection | Manual fetch-based checks | React Native's NetInfo or AppState | Edge cases with airplane mode, captive portals, etc. |

**Key insight:** The OpenAI Realtime API via WebRTC handles audio capture and playback through the peer connection's media tracks -- do not try to capture audio separately with expo-audio and send it over WebSocket. That approach is far more complex and error-prone.

## Common Pitfalls

### Pitfall 1: @openai/agents Not Working on React Native
**What goes wrong:** Importing `@openai/agents/realtime` fails with missing Node.js APIs (ws, crypto, etc.)
**Why it happens:** The SDK targets Node.js and browser environments, not React Native's JavaScriptCore/Hermes runtime
**How to avoid:** Use raw WebRTC via react-native-webrtc. Port the agent instructions and tool definitions, but handle the protocol directly.
**Warning signs:** Build errors mentioning `ws`, `crypto`, or `navigator.mediaDevices` differences

### Pitfall 2: WebRTC Permission Handling on iOS/Android
**What goes wrong:** Audio capture fails silently or app crashes without microphone permission
**Why it happens:** react-native-webrtc requires explicit permission requests; iOS needs NSMicrophoneUsageDescription in Info.plist
**How to avoid:** Request permissions before creating the peer connection; add Info.plist keys via app.json expo config plugin
**Warning signs:** Blank/silent audio, permission dialog not appearing

### Pitfall 3: Sentry Expo Plugin Requires Rebuild
**What goes wrong:** Sentry doesn't capture native crashes after `npx expo install`
**Why it happens:** @sentry/react-native requires native modules; Expo dev client must be rebuilt
**How to avoid:** After adding the Sentry plugin to app.json, run `npx expo prebuild --clean` and rebuild the dev client
**Warning signs:** "Sentry native SDK is not available" warnings in console

### Pitfall 4: Audio Feedback Loop in Realtime
**What goes wrong:** The AI hears its own audio output and responds to itself in a loop
**Why it happens:** Speaker output feeds back into microphone
**How to avoid:** OpenAI Realtime API has built-in echo cancellation via WebRTC; ensure you're using the standard WebRTC audio flow (not capturing audio separately). If issues persist, configure `turn_detection` in session config.
**Warning signs:** AI starts talking to itself repeatedly

### Pitfall 5: Metro Config Conflict with Sentry
**What goes wrong:** Build fails or source maps don't upload
**Why it happens:** Current metro.config.js uses `getDefaultConfig` from expo; Sentry needs `getSentryExpoConfig`
**How to avoid:** Chain the configs: `getSentryExpoConfig` wraps the base config, then `withNativeWind` wraps that
**Warning signs:** "Unable to symbolicate" errors in Sentry dashboard

### Pitfall 6: Data Channel Message Ordering
**What goes wrong:** Tool call responses arrive before the tool call event is processed
**Why it happens:** WebRTC data channels are ordered by default, but event handling may be async
**How to avoid:** Process data channel events sequentially; use a queue if needed for tool call execution
**Warning signs:** "Unknown tool call ID" errors, missed responses

## Code Examples

### Sentry Initialization in Root Layout
```typescript
// apps/mobile/app/_layout.tsx
import * as Sentry from '@sentry/react-native';

Sentry.init({
  dsn: 'YOUR_SENTRY_DSN', // Create new project in Sentry for mobile
  tracesSampleRate: 1.0,
  enableAutoSessionTracking: true,
  sessionTrackingIntervalMillis: 30000,
});

// Wrap the root component export
export default Sentry.wrap(RootLayout);
```

### Metro Config with Sentry + NativeWind
```javascript
// apps/mobile/metro.config.js
const { getSentryExpoConfig } = require('@sentry/react-native/metro');
const { withNativeWind } = require('nativewind/metro');

const config = getSentryExpoConfig(__dirname);
config.resolver.sourceExts.push('sql');

module.exports = withNativeWind(config, { input: './global.css' });
```

### Sync Status Hook
```typescript
// apps/mobile/hooks/useSyncStatus.ts
import { useState, useEffect } from 'react';
import { onSyncStatusChange, type SyncStatus } from '@/lib/sync/status';

export function useSyncStatus() {
  const [status, setStatus] = useState<SyncStatus>('not-synced');
  const [lastSyncAt, setLastSyncAt] = useState<number | null>(null);

  useEffect(() => {
    return onSyncStatusChange((s, t) => {
      setStatus(s);
      setLastSyncAt(t);
    });
  }, []);

  return { status, lastSyncAt };
}
```

### Tool Call Handling in Data Channel
```typescript
// When receiving function_call events from OpenAI Realtime data channel
async function handleToolCall(event: any, bookId: string) {
  if (event.type === 'response.function_call_arguments.done') {
    const { call_id, name, arguments: args } = event;

    if (name === 'bookContext') {
      const parsed = JSON.parse(args);
      // Use existing local RAG pipeline
      const queryVector = await embedSingle(parsed.queryText);
      const results = searchSimilarChunks(bookId, queryVector, 3);
      const context = results.map(r => r.text).join('\n\n');

      // Send tool result back via data channel
      dataChannel.send(JSON.stringify({
        type: 'conversation.item.create',
        item: {
          type: 'function_call_output',
          call_id,
          output: context,
        }
      }));
      dataChannel.send(JSON.stringify({ type: 'response.create' }));
    }
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| sentry-expo package | @sentry/react-native with Expo plugin | Jan 2024 (SDK 50) | Direct integration, no wrapper needed |
| OpenAI Realtime via WebSocket only | WebRTC + WebSocket + SIP | Late 2024/2025 | WebRTC recommended for client-side; handles audio natively |
| @openai/agents browser-only | Community fork for RN + raw WebRTC | 2025-2026 | Official RN support pending; raw WebRTC is production-ready |

**Deprecated/outdated:**
- `sentry-expo`: Deprecated since Jan 2024. Use `@sentry/react-native` directly.
- `OpenAI-Beta: realtime=v1` header: Removed in GA release. Use standard auth.

## Open Questions

1. **Sentry DSN for mobile project**
   - What we know: Web app uses DSN `79d31f9f...@o4510586781958144.ingest.de.sentry.io/4510586797555792`; desktop uses Rust sentry crate
   - What's unclear: Whether to reuse the same Sentry project or create a new one for mobile
   - Recommendation: Create a new Sentry project for the mobile app (separate platform tracking) and use its DSN. The Sentry org ID (`o4510586781958144`) stays the same.

2. **react-native-webrtc Expo compatibility**
   - What we know: react-native-webrtc v124.0.7 works with React Native 0.81.x; requires custom dev build (not Expo Go)
   - What's unclear: Whether an Expo config plugin is needed or if autolinking suffices
   - Recommendation: The app already uses a custom dev client (not Expo Go), so autolinking should work. Add it to app.json plugins if a config plugin is available.

3. **Guardrail latency impact on realtime**
   - What we know: Desktop guardrails run as a separate Agent inference call for each AI output
   - What's unclear: Whether adding a Worker LLM round-trip for classification introduces noticeable latency in realtime voice
   - Recommendation: Run guardrail check asynchronously after audio starts playing. If tripwire fires, interrupt playback and show a message. This avoids blocking the realtime audio stream.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Jest 30.3 + ts-jest 29.4 |
| Config file | apps/mobile/jest.config.js |
| Quick run command | `cd apps/mobile && npx jest --testPathPattern=PATTERN -x` |
| Full suite command | `cd apps/mobile && npx jest` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PARITY-M01 | Realtime session creation and tool call handling | unit | `cd apps/mobile && npx jest --testPathPattern=realtime -x` | No -- Wave 0 |
| PARITY-M02 | Guardrail classification returns correct tripwire | unit | `cd apps/mobile && npx jest --testPathPattern=guardrail -x` | No -- Wave 0 |
| PARITY-M03 | Sync status listener notifies on state changes | unit | `cd apps/mobile && npx jest --testPathPattern=sync-status -x` | No -- Wave 0 |
| PARITY-M04 | Sentry.init called with correct config | unit | `cd apps/mobile && npx jest --testPathPattern=sentry -x` | No -- Wave 0 |

### Sampling Rate
- **Per task commit:** `cd apps/mobile && npx jest --testPathPattern=CHANGED_MODULE -x`
- **Per wave merge:** `cd apps/mobile && npx jest`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `__tests__/realtime.test.ts` -- covers PARITY-M01 (session, tool calls, event handling)
- [ ] `__tests__/guardrails.test.ts` -- covers PARITY-M02 (tripwire classification logic)
- [ ] `__tests__/sync-status.test.ts` -- covers PARITY-M03 (status transitions, listener pattern)
- [ ] Sentry integration is primarily a config concern; manual verification via Sentry dashboard after first crash/error

## Sources

### Primary (HIGH confidence)
- [OpenAI Realtime API docs](https://developers.openai.com/api/docs/guides/realtime) -- WebRTC vs WebSocket architecture, ephemeral keys
- [Sentry React Native Expo setup](https://docs.sentry.io/platforms/react-native/manual-setup/expo/) -- installation, metro config, plugin setup
- Codebase: `apps/main/src/modules/realtime.ts` -- desktop realtime implementation with @openai/agents
- Codebase: `apps/main/src/modules/sync-triggers.ts` -- desktop sync status pattern
- Codebase: `apps/main/src/components/SyncStatusIndicator.tsx` -- desktop sync UI
- Codebase: `workers/worker/src/index.ts` -- `/api/realtime/client_secrets` endpoint

### Secondary (MEDIUM confidence)
- [GitHub Issue #133: @openai/agents-js RN support](https://github.com/openai/openai-agents-js/issues/133) -- confirmed no official RN support; community fork exists
- [expo-webrtc-openai-realtime demo](https://github.com/thorwebdev/expo-webrtc-openai-realtime) -- proof of concept for WebRTC + OpenAI on Expo
- [npm: react-native-webrtc v124.0.7](https://www.npmjs.com/package/react-native-webrtc) -- version verified
- [npm: @sentry/react-native v8.7.0](https://www.npmjs.com/package/@sentry/react-native) -- version verified

### Tertiary (LOW confidence)
- Guardrail-as-server-call approach: Extrapolated from desktop pattern; not validated against real latency

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- react-native-webrtc and @sentry/react-native are well-established, versions verified
- Architecture: MEDIUM -- WebRTC approach for OpenAI Realtime is proven in demos but not yet widely production-tested on RN; guardrail-as-server-call is novel
- Pitfalls: HIGH -- based on known issues with @openai/agents on RN, Sentry Expo integration, and WebRTC permission handling

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable libraries, OpenAI Realtime API is GA)
