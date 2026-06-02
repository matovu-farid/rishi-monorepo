import { fromCallback } from 'xstate'

export type MicInput = {
  getUserMedia?: (c?: MediaStreamConstraints) => Promise<MediaStream>
  constraints?: MediaStreamConstraints
}

export type MicInEvent =
  | { type: 'SET_MUTED'; muted: boolean; source: 'self' | 'host' }
  | { type: 'SET_DEVICE'; deviceId: string }
  | { type: 'ATTACH_REMOTE'; userId: string; stream: MediaStream }
  | { type: 'DETACH_REMOTE'; userId: string }

export type MicOutEvent =
  | { type: 'LOCAL_TRACK_READY'; track: MediaStreamTrack; stream: MediaStream }
  | { type: 'LOCAL_LEVEL'; level: number }
  | { type: 'REMOTE_LEVEL'; userId: string; level: number }
  | { type: 'MIC_DENIED' }
  | { type: 'MIC_ERROR'; message: string }
  | { type: 'MUTE_STATE'; muted: boolean; source: 'self' | 'host' | 'none' }

export const micActor = fromCallback<MicInEvent, MicInput, MicOutEvent>(
  ({ emit, receive, input }) => {
    const gum =
      input.getUserMedia ?? ((c) => navigator.mediaDevices.getUserMedia(c ?? { audio: true }))
    let stream: MediaStream | null = null
    let track: MediaStreamTrack | null = null
    let hostMuted = false
    let selfMuted = false
    let stopped = false

    function applyMuted(): void {
      if (!track) return
      track.enabled = !(hostMuted || selfMuted)
      emit({
        type: 'MUTE_STATE',
        muted: hostMuted || selfMuted,
        source: hostMuted ? 'host' : selfMuted ? 'self' : 'none'
      })
    }

    gum(input.constraints ?? { audio: true })
      .then((s) => {
        if (stopped) {
          for (const t of s.getTracks()) t.stop()
          return
        }
        stream = s
        // `getAudioTracks()` can return an empty array even when getUserMedia
        // resolves — guard on length explicitly so the no-track branch is
        // reachable under TS's control-flow analysis (with
        // `noUncheckedIndexedAccess` off, indexing types as non-undefined).
        const audioTracks = s.getAudioTracks()
        if (audioTracks.length === 0) {
          emit({ type: 'MIC_ERROR', message: 'no_audio_track' })
          return
        }
        track = audioTracks[0]
        emit({ type: 'LOCAL_TRACK_READY', track, stream: s })
      })
      .catch((err: unknown) => {
        const name = (err as { name?: string }).name
        if (name === 'NotAllowedError' || name === 'PermissionDeniedError') {
          emit({ type: 'MIC_DENIED' })
        } else {
          emit({
            type: 'MIC_ERROR',
            message: err instanceof Error ? err.message : 'mic_unavailable'
          })
        }
      })

    receive((evt) => {
      if (stopped) return
      switch (evt.type) {
        case 'SET_MUTED':
          if (evt.source === 'host') hostMuted = evt.muted
          else {
            if (hostMuted && !evt.muted) return
            selfMuted = evt.muted
          }
          applyMuted()
          break
        case 'ATTACH_REMOTE':
        case 'DETACH_REMOTE':
        case 'SET_DEVICE':
          break
      }
    })

    return () => {
      stopped = true
      if (stream) for (const t of stream.getTracks()) t.stop()
    }
  }
)
