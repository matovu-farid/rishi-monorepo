# Voice Chat Pipeline

End-to-end sequence of a voice chat session in the iOS app — from the user tapping the mic button in `ChatPanelHost` through OpenAI's Realtime API, on-device RAG against the open book, and persisted transcripts.

Broken into four diagrams by lifecycle phase:

1. [Session start](#1-session-start) — permissions, key fetch, embedder prewarm, WebRTC connect
2. [Turn — user speech → LLM](#2-turn--user-speech--llm) — server-side VAD + STT, live transcript UI
3. [Turn — RAG tool callback + response](#3-turn--rag-tool-callback--response) — `bookContext` tool call, HNSW search, TTS audio back
4. [Transcript persistence (parallel)](#4-transcript-persistence-parallel) — `VoiceTranscriptBridge` writes finalized messages
5. [Session end](#5-session-end) — ordered teardown so in-flight tool results don't race

## Participants

| Participant | File | Notes |
|---|---|---|
| `ChatPanelHost` | `rishi/rishi/Views/ChatPanelHost.swift` | SwiftUI entry, "Start voice session" button |
| `VoiceSessionPresenter` | `rishi/rishi/Voice/VoiceSessionPresenter.swift` | `@MainActor` presenter, owns `bridgeTask` |
| `RealtimeVoiceSession` | `Packages/RishiVoice/.../RealtimeVoiceSession.swift` | actor, owns `responderTask` + lifecycle |
| `AudioSessionCoordinator` | `Packages/RishiVoice/...` | `AVAudioSession` + `MicPermissionGate` |
| `EphemeralKeyFetcher` | `Packages/RishiVoice/...` | short-lived API key from worker |
| `RealtimeAPIAdapter` | `Packages/RishiVoice/.../RealtimeAPIAdapter.swift` | wraps `swift-realtime-openai` SDK |
| OpenAI Realtime API | server | server-side VAD, STT, LLM, TTS over WebRTC |
| `BookContextResponder` | `Packages/RishiVoice/Service/BookContextResponder.swift` | actor, handles `bookContext` tool |
| `USearchBookSearch` + `CoreMLMiniLMEmbedder` | `Packages/RishiSearch/...` | HNSW + on-device embeddings |
| `VoiceTranscriptBridge` | `Packages/RishiVoice/Service/VoiceTranscriptBridge.swift` | actor, persists finalized transcripts |
| `MessageStore` | GRDB-backed | chat persistence + sync hook |
| `VoiceSessionState` | `Packages/RishiVoice/State/VoiceSessionState.swift` | `@Observable` partial-transcript buffers |

---

## 1. Session start

Permissions, ephemeral key fetch, and embedder prewarm run in parallel to hide the ~500 ms CoreML cold-load behind the network round-trip. Only then does the WebRTC peer connection get established.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant View as ChatPanelHost
    participant Pres as VoiceSessionPresenter
    participant Sess as RealtimeVoiceSession
    participant Audio as AudioSessionCoordinator
    participant Key as EphemeralKeyFetcher
    participant RAG as CoreMLMiniLMEmbedder
    participant SDK as RealtimeAPIAdapter
    participant API as OpenAI Realtime API

    User->>+View: tap "Start voice session"
    View->>+Pres: start(bookId:)
    Pres->>+Sess: start(bookId:, context:)

    par permissions & audio
        Sess->>+Audio: request mic + activate .voice
        Audio-->>-Sess: granted, AVAudioSession active
    and key + embedder prewarm
        Sess->>+Key: fetch(language:, bookContext:)
        Key-->>-Sess: ephemeralKey + tool spec
        Sess->>+RAG: prewarm
        RAG-->>-Sess: embedder ready
    end

    Sess->>+SDK: connect(ephemeralKey:)
    SDK->>+API: WebRTC SDP offer/answer
    API-->>-SDK: peer up, mic streaming
    SDK-->>-Sess: connected

    Sess->>Sess: spawn responderTask
    Sess-->>-Pres: ready
    Pres->>Pres: spawn bridgeTask
    Pres-->>-View: status = .listening
    View-->>-User: live UI
```

---

## 2. Turn — user speech → LLM

Server-side VAD on the OpenAI side decides when the user has stopped talking (700 ms silence, 300 ms prefix padding). Partial and final transcript events flow back through the SDK and update the `@Observable` state that drives the live ticker.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant API as OpenAI Realtime API
    participant SDK as RealtimeAPIAdapter
    participant Sess as RealtimeVoiceSession
    participant State as VoiceSessionState
    participant View as ChatPanelHost

    User->>+API: speech (PCM 24 kHz, WebRTC)
    Note over API: server-side VAD<br/>700 ms silence<br/>300 ms prefix padding

    loop transcript events
        API-->>SDK: partial / final user transcript
        SDK-->>Sess: transcriptStream() yields event
        Sess->>State: update partialUserTranscript
        State-->>View: re-render ticker
    end

    API->>-API: LLM plans response<br/>(may call bookContext tool — see diagram 3)
```

---

## 3. Turn — RAG tool callback + response

The LLM decides *when* to fetch book context. When it does, the SDK surfaces a `tool_call` that the `BookContextResponder` handles on-device against the open book's HNSW index. The LLM then resumes generation and the response is streamed back as both text (for the ticker) and TTS audio (played by the SDK directly).

```mermaid
sequenceDiagram
    autonumber
    participant API as OpenAI Realtime API
    participant SDK as RealtimeAPIAdapter
    participant Resp as BookContextResponder
    participant RAG as USearchBookSearch +<br/>MiniLMEmbedder
    participant Sess as RealtimeVoiceSession
    participant State as VoiceSessionState
    actor User

    opt LLM calls bookContext(query)
        API-->>SDK: tool_call(bookContext, query)
        SDK-->>+Resp: toolCallStream() yields call
        Resp->>Resp: gate on BookSearch.status

        alt index ready
            Resp->>+RAG: search(query, bookId, k=3)
            RAG->>RAG: embed query → HNSW top-k → chunk lookup
            RAG-->>-Resp: [BookSearchHit]
            Resp->>SDK: sendToolResult(callId, hits)
        else cold-start / not ready
            Resp->>SDK: sendToolResult(callId, sentinel)
        end
        Resp-->>-SDK: done
        SDK->>API: tool result over data channel
    end

    API-->>SDK: assistant text deltas
    API-->>SDK: TTS audio frames
    SDK-->>User: speaker playback (WebRTC out)
    SDK-->>Sess: assistant transcript events
    Sess->>State: update partialAssistantTranscript
```

---

## 4. Transcript persistence (parallel)

`VoiceTranscriptBridge` runs as a parallel consumer of the same transcript stream. It only writes on `isFinal=true`, so partial-transcript churn never hits disk. The `VoiceTranscriptDirtyHook` lets `SyncEngine` pick up new messages without polling.

```mermaid
sequenceDiagram
    autonumber
    participant SDK as RealtimeAPIAdapter
    participant Bridge as VoiceTranscriptBridge
    participant Store as MessageStore (GRDB)
    participant Sync as SyncEngine

    Note over Bridge: spawned by VoiceSessionPresenter<br/>as bridgeTask at session start

    loop until cancelled
        SDK-->>+Bridge: transcript event
        alt isFinal == true
            Bridge->>+Store: upsert(Message)
            Store-->>-Bridge: ok
            Bridge->>Sync: fire VoiceTranscriptDirtyHook
        else partial
            Bridge->>Bridge: skip
        end
        Bridge-->>-SDK: ack
    end
```

---

## 5. Session end

Teardown order is load-bearing: `responderTask` is cancelled *before* `client.disconnect()` so it can't attempt `sendToolResult` on a closed data channel. The audio session is released last.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant View as ChatPanelHost
    participant Pres as VoiceSessionPresenter
    participant Sess as RealtimeVoiceSession
    participant SDK as RealtimeAPIAdapter
    participant API as OpenAI Realtime API
    participant Audio as AudioSessionCoordinator

    User->>+View: tap "End session"
    View->>+Pres: end()
    Pres->>Pres: cancel bridgeTask
    Pres->>+Sess: end()

    Sess->>Sess: cancel responderTask
    Note right of Sess: cancel BEFORE disconnect<br/>so in-flight tool results<br/>don't race
    Sess->>Sess: cancel statusObservationTask

    Sess->>+SDK: disconnect()
    SDK->>API: close WebRTC peer
    SDK-->>-Sess: closed

    Sess->>+Audio: releaseActiveMode(.voice)
    Audio-->>-Sess: AVAudioSession deactivated

    Sess-->>-Pres: ended
    Pres-->>-View: status = .idle
    View-->>-User: collapsed chat panel
```

---

## Design notes

- **No on-device STT or TTS.** Both happen server-side in the OpenAI Realtime API. The SDK owns mic capture and speaker playback; raw PCM frames never surface to `RishiVoice`.
- **RAG is a tool callback, not a pre-prompt step.** The LLM decides when to call `bookContext(query)`; on-device search only runs on demand. This keeps cold-start cheap and lets the model issue multiple queries per turn.
- **Embedder prewarm is parallelized** with the ephemeral key fetch to hide the ~500 ms CoreML cold-load behind the network round-trip.
- **Two parallel consumers of `transcriptStream()`**: `RealtimeVoiceSession` drives live UI state, `VoiceTranscriptBridge` persists final messages. UI never blocks on disk writes.
- **Teardown ordering is load-bearing.** Cancelling `responderTask` before `client.disconnect()` prevents the responder from attempting `sendToolResult` on a closed data channel.
