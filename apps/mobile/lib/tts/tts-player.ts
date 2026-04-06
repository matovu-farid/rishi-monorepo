import { createAudioPlayer } from 'expo-audio'

export type TTSPlayerStatus = 'idle' | 'loading' | 'playing' | 'paused'

/**
 * Audio player wrapper for TTS playback.
 * Uses expo-audio's createAudioPlayer (non-React API) for play/pause/stop.
 */
export class TTSPlayer {
  private _player: ReturnType<typeof createAudioPlayer>
  private _status: TTSPlayerStatus = 'idle'
  private _subscription: { remove: () => void } | null = null

  /** Callback fired when the current audio finishes playing */
  onPlaybackFinished: (() => void) | null = null

  constructor() {
    this._player = createAudioPlayer()
    this._setupListener()
  }

  /** Current playback status */
  get status(): TTSPlayerStatus {
    return this._status
  }

  /**
   * Play audio from a local file URI.
   * Sets the source and starts playback.
   */
  async play(uri: string): Promise<void> {
    this._status = 'loading'
    this._player.replace({ uri })
    this._player.play()
    this._status = 'playing'
  }

  /**
   * Pause current playback.
   */
  pause(): void {
    if (this._status === 'playing') {
      this._player.pause()
      this._status = 'paused'
    }
  }

  /**
   * Resume playback from paused state.
   */
  resume(): void {
    if (this._status === 'paused') {
      this._player.play()
      this._status = 'playing'
    }
  }

  /**
   * Stop playback and reset to idle.
   */
  stop(): void {
    this._player.pause()
    this._status = 'idle'
  }

  /**
   * Release player resources.
   */
  cleanup(): void {
    this._subscription?.remove()
    this._subscription = null
    this._player.remove()
    this._status = 'idle'
  }

  private _setupListener(): void {
    this._subscription = this._player.addListener('playbackStatusUpdate', (event: any) => {
      if (event.didJustFinish) {
        this._status = 'idle'
        this.onPlaybackFinished?.()
      }
    })
  }
}
