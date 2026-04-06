import { useCallback, useEffect, useRef, useState } from 'react'
import * as FileSystem from 'expo-file-system'
import { TTSQueue } from '@/lib/tts/tts-queue'
import { TTSPlayer, TTSPlayerStatus } from '@/lib/tts/tts-player'

interface UseTTSPlayerReturn {
  status: TTSPlayerStatus
  currentChunkIndex: number
  totalChunks: number
  isActive: boolean
  play: () => void
  pause: () => void
  stop: () => void
  next: () => void
  previous: () => void
}

/**
 * React hook that orchestrates TTSQueue and TTSPlayer together.
 * Manages chunk loading, audio fetching, sequential playback, and cleanup.
 */
export function useTTSPlayer(
  bookId: string,
  filePath: string,
  format: 'epub' | 'pdf'
): UseTTSPlayerReturn {
  const queueRef = useRef<TTSQueue | null>(null)
  const playerRef = useRef<TTSPlayer | null>(null)

  const [status, setStatus] = useState<TTSPlayerStatus>('idle')
  const [currentChunkIndex, setCurrentChunkIndex] = useState(0)
  const [totalChunks, setTotalChunks] = useState(0)

  // Initialize player on mount
  useEffect(() => {
    const player = new TTSPlayer()
    playerRef.current = player

    return () => {
      player.cleanup()
      playerRef.current = null
      // Clean up cached audio files
      queueRef.current?.cleanupAll()
    }
  }, [])

  /**
   * Play a specific chunk by index.
   */
  const playChunk = useCallback(async (queue: TTSQueue, player: TTSPlayer, index: number) => {
    const chunk = queue.chunks[index]
    if (!chunk) return

    setStatus('loading')
    try {
      const uri = await queue.requestTTSAudio(chunk.text, chunk.id)
      await player.play(uri)
      setStatus('playing')
      setCurrentChunkIndex(index)

      // Prefetch next chunks in background
      queue.prefetchNext(2)

      // Clean up previously played chunk audio (if not current or adjacent)
      if (index > 1) {
        const prevChunk = queue.chunks[index - 2]
        if (prevChunk) {
          queue.deleteCachedAudio(prevChunk.id)
        }
      }
    } catch (error) {
      console.error('[TTS] Error playing chunk:', error)
      setStatus('idle')
    }
  }, [])

  /**
   * Set up playback finished callback to auto-advance.
   */
  const setupOnFinished = useCallback((queue: TTSQueue, player: TTSPlayer) => {
    player.onPlaybackFinished = () => {
      const hasNext = queue.next()
      if (hasNext) {
        setCurrentChunkIndex(queue.currentIndex)
        playChunk(queue, player, queue.currentIndex)
      } else {
        // Reached end of book
        setStatus('idle')
        setCurrentChunkIndex(0)
        queue.reset()
      }
    }
  }, [playChunk])

  /**
   * Start or resume TTS playback.
   */
  const play = useCallback(async () => {
    const player = playerRef.current
    if (!player) return

    // If paused, just resume
    if (status === 'paused') {
      player.resume()
      setStatus('playing')
      return
    }

    // If already playing or loading, no-op
    if (status === 'playing' || status === 'loading') return

    setStatus('loading')

    try {
      // Create or reuse queue
      let queue = queueRef.current
      if (!queue || queue.bookId !== bookId) {
        queue = new TTSQueue(bookId, filePath, format)
        queueRef.current = queue
      }

      // Ensure book has chunks
      await queue.ensureBookChunked()
      queue.loadChunks()

      const total = queue.getTotalChunks()
      setTotalChunks(total)

      if (total === 0) {
        console.warn('[TTS] No chunks available for this book')
        setStatus('idle')
        return
      }

      // Set up auto-advance
      setupOnFinished(queue, player)

      // Start playing from current position
      await playChunk(queue, player, queue.currentIndex)
    } catch (error) {
      console.error('[TTS] Error starting playback:', error)
      setStatus('idle')
    }
  }, [bookId, filePath, format, status, playChunk, setupOnFinished])

  /**
   * Pause current playback.
   */
  const pause = useCallback(() => {
    playerRef.current?.pause()
    setStatus('paused')
  }, [])

  /**
   * Stop playback and reset to idle.
   */
  const stop = useCallback(() => {
    const player = playerRef.current
    const queue = queueRef.current

    player?.stop()
    queue?.reset()
    queue?.cleanupAll()

    setStatus('idle')
    setCurrentChunkIndex(0)
  }, [])

  /**
   * Skip to the next chunk.
   */
  const next = useCallback(() => {
    const queue = queueRef.current
    const player = playerRef.current
    if (!queue || !player) return

    const hasNext = queue.next()
    if (hasNext) {
      setCurrentChunkIndex(queue.currentIndex)
      playChunk(queue, player, queue.currentIndex)
    }
  }, [playChunk])

  /**
   * Go back to the previous chunk.
   */
  const previous = useCallback(() => {
    const queue = queueRef.current
    const player = playerRef.current
    if (!queue || !player) return

    const hasPrev = queue.previous()
    if (hasPrev) {
      setCurrentChunkIndex(queue.currentIndex)
      playChunk(queue, player, queue.currentIndex)
    }
  }, [playChunk])

  return {
    status,
    currentChunkIndex,
    totalChunks,
    isActive: status !== 'idle',
    play,
    pause,
    stop,
    next,
    previous,
  }
}
