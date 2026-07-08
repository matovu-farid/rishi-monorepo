# @unchecked Sendable Audit

Audit date: 2026-06-13
Author: subagent (review before acting on CONVERT items)

## TL;DR

Audited 50 in-scope `@unchecked Sendable` declarations across the apple
packages and `rishi/` app target (Tests/ and RishiTesting/ excluded). 24 were
historical hedges where every stored property was already a Sendable `let` —
promoted to plain `Sendable` and verified with per-package SPM builds. 26
remain `@unchecked` because they hold genuine non-Sendable state
(`UserDefaults`, AVFoundation engines, Readium `Publication`, PDFKit
`PDFDocument`, `var`-mutable observable VMs, MainActor-pinned reference
graphs); each now carries a one-line rationale comment above the declaration.
No CONVERT candidates surfaced — the remaining types are at the right shape
for now.

## Promoted (now compiler-proven Sendable)

| Type | File | Why it was safe to promote |
|---|---|---|
| `PositionUploader` | `RishiSync/Outbound/PositionUploader.swift` | All stored props `let`; WorkerClient is an actor, store protocols inherit Sendable. |
| `RemoteChangeFetcher` | `RishiSync/Inbound/RemoteChangeFetcher.swift` | Same pattern — let + actor + Sendable protocols. |
| `MessageUploader` | `RishiSync/Outbound/MessageUploader.swift` | Same. |
| `ChangeApplier` | `RishiSync/Inbound/ChangeApplier.swift` | Same — all let store refs. |
| `MessagesFetcher` | `RishiSync/Inbound/MessagesFetcher.swift` | Same. |
| `ConversationsFetcher` | `RishiSync/Inbound/ConversationsFetcher.swift` | Same. |
| `HighlightUploader` | `RishiSync/Outbound/HighlightUploader.swift` | Same. |
| `BookUploader` | `RishiSync/Outbound/BookUploader.swift` | All let; URLSession + BookFileStorage (actor) + Sendable protocols. |
| `ConversationUploader` | `RishiSync/Outbound/ConversationUploader.swift` | Same uploader pattern. |
| `SyncMetadataStore` | `RishiSync/Storage/SyncMetadataStore.swift` | Only `let dbQueue`; the database layer serializes access. |
| `BookStore` | `RishiDB/Stores/BookStore.swift` | Only `let dbQueue`. |
| `MessageStore` | `RishiDB/Stores/MessageStore.swift` | Same. |
| `HighlightStore` | `RishiDB/Stores/HighlightStore.swift` | Same. |
| `PositionStore` | `RishiDB/Stores/PositionStore.swift` | Same. |
| `ConversationStore` | `RishiDB/Stores/ConversationStore.swift` | Same. |
| `SystemAudioApplicationProbe` | `RishiVoice/Permissions/SystemMicPermissionGate.swift` | Stateless struct over OS singletons; no stored props. |
| `InMemoryKeychainBackend` | `RishiAuth/Keychain/InMemoryKeychainBackend.swift` | Only stored prop is `OSAllocatedUnfairLock<[Key: Data]>`, which is Sendable. |
| `EPUBPublicationLoader` | `RishiReader/EPUB/EPUBPublicationLoader.swift` | Only stored prop is `EPUBUnpackedCache?` (actor). Non-Sendable Readium types are method-local. |
| `EmptyBookStore` (DragDrop preview helper) | `RishiLibrary/Import/DragDropImport.swift` | Empty class, no stored properties. |
| 5 reader-preview `ReaderSettingsStore` helpers | `RishiReader/UI/{EPUBTypographyPicker,PDFReaderScreen,EPUBThemePicker,EPUBReaderScreen,PDFThemePicker}.swift` | Empty classes used only by `#Preview` blocks. |

Per-package SPM builds were green after each batch.

## Kept (rationale documented)

| Type | File | Reason `@unchecked` is necessary |
|---|---|---|
| `SinkRegistry`, `TestCaptureBox` | `RishiLogging/Log.swift` | Mutable `var` state under NSLock. |
| `SimulatorDumpSink` | `RishiLogging/Sinks/SimulatorDumpSink.swift` | Mutable file handles owned by a serial DispatchQueue. |
| `UserDefaultsOnboardingState` | `RishiOnboarding/Storage/OnboardingState.swift` | Holds `UserDefaults`, non-Sendable. |
| `EngineHolder` | `RishiSync/Engine/SyncEngine.swift` | Mutable `weak var engine`. |
| `SyncStatus` | `RishiSync/Engine/SyncStatus.swift` | `@Observable` with `var` fields. |
| `UserDefaultsTTSSettingsStore` | `RishiAudio/Settings/TTSSettingsStore.swift` | Holds `UserDefaults`. |
| `AVAudioSessionConfigurator` | `RishiAudio/Coordinator/AudioSessionConfigurator.swift` | Wraps non-Sendable `AVAudioSession` + NotificationCenter token. |
| `FakeAudioSessionConfigurator` | same | Mutable assertion-capture vars under NSLock. |
| `ConvertCarrier` (MP3StreamDecoder local) | `RishiAudio/TTS/MP3StreamDecoder.swift` | Holds `AVAudioCompressedBuffer` + mutable `var done`. |
| `FakeNowPlayingInfoSurface`, `FakeRemoteCommandSurface` | `RishiAudio/TTS/NowPlayingProtocol.swift` | Mutable test-capture vars under NSLock. |
| `AVAudioEngineAdapter` | `RishiAudio/TTS/AudioEngineProtocol.swift` | Wraps non-Sendable AVAudioEngine + AVAudioPlayerNode. |
| `FakeAudioEngine` | same | Mutable test-capture vars under NSLock. |
| `PCMChunk` | `RishiAudio/TTS/PCMChunk.swift` | Holds non-Sendable `AVAudioPCMBuffer`. |
| `RealtimeAPIAdapter` | `RishiVoice/Service/RealtimeAPIAdapter.swift` | Mutable `var conversation` + stream continuations under NSLock. |
| `UserDefaultsTelemetryStore` | `RishiSettings/Telemetry/TelemetryStore.swift` | Holds `UserDefaults`. |
| `SampleBookInstaller` | `RishiLibrary/Storage/SampleBookInstaller.swift` | Holds `UserDefaults`. |
| `UserDefaultsReaderSettingsStore` | `RishiReader/Storage/UserDefaultsReaderSettingsStore.swift` | Holds `UserDefaults`. |
| `HighlightCacheBox` (PDF) | `RishiReader/PDF/PDFReaderViewModel+Highlights.swift` | Mutable `var storage` dictionary under NSLock. |
| `PDFReaderViewModel` | `RishiReader/PDF/PDFReaderViewModel.swift` | `@Observable` with `var` fields; holds `PDFDocument?`. |
| `SampleReaderInstaller` | `RishiReader/Storage/SampleReaderInstaller.swift` | Holds `UserDefaults`. |
| `EPUBHighlightCacheBox` | `RishiReader/EPUB/EPUBReaderViewModel+Highlights.swift` | Mutable `var storage` dictionary under NSLock. |
| `EPUBReaderViewModel` | `RishiReader/EPUB/EPUBReaderViewModel.swift` | `@Observable` with `var` fields; holds Readium `Publication?`. |
| `AudioStack` | `rishi/rishi/AppDependencies.swift` | Struct holding MainActor-pinned ViewModel-style references that lack Sendable upstream. |
| `BootstrappedServices` | `rishi/rishi/AppDependencies.swift` | Same — composite of MainActor-pinned references. |

## Flagged for CONVERT (proposal — not executed)

None. Every remaining `@unchecked Sendable` either wraps a genuinely
non-Sendable Apple framework type, holds `UserDefaults`, or backs an
`@Observable` SwiftUI view-model whose mutation surface is exactly what the
type is there to provide. Converting these would be a behaviour change, not
a Sendable hygiene change, and is out of scope for this audit.

## Patterns seen

- The biggest single bucket of promotions was RishiSync uploaders / fetchers
  and the database-backed stores in RishiDB / RishiSync. They were copy-pasted
  out of an earlier era where the project was still on Swift 5 and the
  persistence layer had not yet been audited for strict-concurrency
  friendliness. The compiler can now prove these directly.
- `UserDefaults` is the single biggest reason a class stays `@unchecked`.
  Foundation still doesn't mark it Sendable despite the documented thread
  safety of its scalar accessors. Six classes (in onboarding / TTS settings /
  telemetry / sample installers / reader settings) all share this one
  reason.
- AVFoundation reference types (`AVAudioSession`, `AVAudioEngine`,
  `AVAudioPlayerNode`, `AVAudioPCMBuffer`) are the second biggest bucket —
  none of them are `Sendable` and the wrappers serialise mutation through
  NSLock.
- Readium 3.x `Publication` and PDFKit `PDFDocument` are non-Sendable and
  the reader VMs `@preconcurrency import` them. Promotion isn't possible
  without an engine-replacement-scale refactor.
- The 5 preview-only `ReaderSettingsStore` helpers in `RishiReader/UI/` are
  identical empty classes — a candidate for de-duplication into a single
  shared `EphemeralReaderSettingsStore` in a future refactor.
