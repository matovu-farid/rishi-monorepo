jest.mock('expo-audio', () => {
  const mockPlayer = {
    play: jest.fn(),
    pause: jest.fn(),
    replace: jest.fn(),
    remove: jest.fn(),
    addListener: jest.fn(() => ({ remove: jest.fn() })),
    currentStatus: 'idle',
  }
  return {
    createAudioPlayer: jest.fn(() => mockPlayer),
    AudioPlayer: jest.fn(),
  }
})

import { TTSPlayer } from '@/lib/tts/tts-player'
import { createAudioPlayer } from 'expo-audio'

const mockCreateAudioPlayer = createAudioPlayer as jest.MockedFunction<typeof createAudioPlayer>

describe('TTSPlayer', () => {
  let player: TTSPlayer

  beforeEach(() => {
    jest.clearAllMocks()
    player = new TTSPlayer()
  })

  afterEach(() => {
    player.cleanup()
  })

  describe('play', () => {
    it('transitions state from idle to playing', async () => {
      expect(player.status).toBe('idle')
      await player.play('/cache/tts-c1.mp3')
      expect(player.status).toBe('playing')
    })
  })

  describe('pause', () => {
    it('transitions state from playing to paused', async () => {
      await player.play('/cache/tts-c1.mp3')
      player.pause()
      expect(player.status).toBe('paused')
    })
  })

  describe('stop', () => {
    it('resets state to idle and clears current audio', async () => {
      await player.play('/cache/tts-c1.mp3')
      player.stop()
      expect(player.status).toBe('idle')
    })
  })

  describe('resume', () => {
    it('transitions state from paused to playing', async () => {
      await player.play('/cache/tts-c1.mp3')
      player.pause()
      expect(player.status).toBe('paused')
      player.resume()
      expect(player.status).toBe('playing')
    })
  })
})
