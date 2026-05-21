/**
 * Mobile MediaPort. Wraps `react-native-webrtc` to satisfy the contract
 * the shared activation pipeline expects:
 *   - `getUserMedia` returns a MediaStreamLike.
 *   - `createAudioElement` returns a dummy AudioElementLike — RN has no
 *     `<audio>` element; expo-audio is wired through expo-audio's
 *     player on the TTS side, not here. The shared pipeline only ever
 *     toggles `.muted` / `.srcObject = null` / `.pause()` on this — all
 *     of which we no-op.
 *   - `cloneStreamForWebrtcSend` clones the audio tracks into a new
 *     MediaStream whose tracks start with `enabled = false`.
 *   - `createMediaRecorder` is OMITTED on mobile (no equivalent of
 *     `MediaRecorder` on React Native). The activation pipeline already
 *     branches on `deps.media.createMediaRecorder` being undefined and
 *     skips the buffered-speech-replay feature.
 *
 * Microphone permissions: we request the OS permission inline before
 * `mediaDevices.getUserMedia`. iOS triggers the permission dialog via
 * getUserMedia itself; Android needs an explicit
 * `PermissionsAndroid.request(RECORD_AUDIO)` call first.
 */
import { Platform, PermissionsAndroid } from 'react-native'
import { mediaDevices, MediaStream as RnMediaStream } from 'react-native-webrtc'
import type {
  AudioElementLike,
  MediaPort,
  MediaStreamLike,
  VoiceChatMediaConstraints
} from '@rishi/shared/voice-chat'

async function requestMicPermissionAndroid(): Promise<void> {
  if (Platform.OS !== 'android') return
  const granted = await PermissionsAndroid.request(
    PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
    {
      title: 'Microphone Permission',
      message: 'This app needs microphone access for voice conversations with AI.',
      buttonPositive: 'Allow',
      buttonNegative: 'Deny'
    }
  )
  if (granted !== PermissionsAndroid.RESULTS.GRANTED) {
    const err = new Error('Microphone permission denied')
    ;(err as { name: string }).name = 'NotAllowedError'
    throw err
  }
}

export const mobileMediaPort: MediaPort = {
  async getUserMedia(constraints: VoiceChatMediaConstraints): Promise<MediaStreamLike> {
    await requestMicPermissionAndroid()
    // react-native-webrtc's `Constraints` type is structurally identical
    // to the WHATWG `MediaStreamConstraints` shape we accept here, but
    // its `MediaTrackConstraints.facingMode` is narrower
    // (`ConstrainString` vs DOM's `ConstrainDOMString`). The
    // voice-chat callers never set facingMode (audio only), so the
    // cast-through-unknown is safe.
    const stream = await mediaDevices.getUserMedia(
      constraints as unknown as Parameters<typeof mediaDevices.getUserMedia>[0]
    )
    return stream as unknown as MediaStreamLike
  },

  createAudioElement(): AudioElementLike {
    // React Native has no <audio> element. The shared pipeline only ever
    // toggles `.muted`, sets `.srcObject = null` on teardown, calls
    // `.pause()`, and reads `.autoplay`. None of those have effect on
    // mobile — the remote audio is rendered by the WebRTC SDK via the
    // platform's native audio session.
    return {
      muted: false,
      srcObject: null,
      autoplay: true,
      pause(): void {
        /* no-op */
      }
    }
  },

  cloneStreamForWebrtcSend(source: MediaStreamLike): MediaStreamLike {
    // Pull the original audio tracks. react-native-webrtc tracks expose
    // `.clone()` per WHATWG.
    const tracks = source.getTracks() as unknown as Array<MediaStreamTrack & { clone(): MediaStreamTrack }>
    const cloned: MediaStreamTrack[] = []
    for (const t of tracks) {
      try {
        const c = typeof t.clone === 'function' ? t.clone() : t
        ;(c as unknown as { enabled: boolean }).enabled = false
        cloned.push(c)
      } catch {
        // Fall back to the original if clone fails. The cloned-stream
        // mute is mostly a safety net; server-side VAD also gates output.
        ;(t as unknown as { enabled: boolean }).enabled = false
        cloned.push(t)
      }
    }
    // Some react-native-webrtc versions accept tracks via the
    // `MediaStream` constructor; others require addTrack. Try both. The
    // RnMediaStream constructor signature differs from the WHATWG one
    // (it takes `tracks | MediaStream | undefined`), so we go via
    // unknown to bypass the narrowed cross-DOM type.
    let mediaStream: unknown
    try {
      mediaStream = new (RnMediaStream as unknown as new (init?: unknown) => unknown)(
        cloned
      )
    } catch {
      mediaStream = new (RnMediaStream as unknown as new () => unknown)()
      const s = mediaStream as { addTrack?: (t: unknown) => void }
      for (const t of cloned) s.addTrack?.(t)
    }
    return mediaStream as MediaStreamLike
  }

  // createMediaRecorder intentionally omitted — see file header.
}
