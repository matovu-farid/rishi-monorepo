/**
 * Tests for useVoiceInput hook logic.
 * Tests the core record -> transcribe -> return text flow by testing
 * the underlying functions directly through the hook's returned interface.
 *
 * Since we don't have @testing-library/react-native, we mock React hooks
 * and call the hook as a plain function.
 */

// --- Mock state management ---
const stateStore: Record<string, any> = {}
let stateCounter = 0

jest.mock('react', () => ({
  useState: (init: any) => {
    const key = `state_${stateCounter++}`
    if (!(key in stateStore)) stateStore[key] = init
    return [stateStore[key], (val: any) => { stateStore[key] = typeof val === 'function' ? val(stateStore[key]) : val }]
  },
}))

// --- Mock expo-audio ---
const mockRecord = jest.fn()
const mockStop = jest.fn()
const mockPrepareToRecordAsync = jest.fn().mockResolvedValue(undefined)
const mockRequestPermissions = jest.fn().mockResolvedValue({ granted: true })

let mockRecorderState = {
  record: mockRecord,
  stop: mockStop,
  prepareToRecordAsync: mockPrepareToRecordAsync,
  isRecording: false,
  uri: 'file://recording.m4a',
}

jest.mock('expo-audio', () => ({
  useAudioRecorder: jest.fn(() => mockRecorderState),
  RecordingPresets: { HIGH_QUALITY: {} },
  requestPermissionsAsync: (...args: any[]) => mockRequestPermissions(...args),
}))

// --- Mock expo-file-system ---
jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn().mockResolvedValue('aGVsbG8='), // base64 of "hello"
  deleteAsync: jest.fn().mockResolvedValue(undefined),
  EncodingType: { Base64: 'base64' },
}))

// --- Mock react-native ---
jest.mock('react-native', () => ({
  Platform: { OS: 'ios' },
}))

// --- Mock apiClient ---
const mockApiClient = jest.fn().mockResolvedValue({
  ok: true,
  json: () => Promise.resolve({ transcript: 'hello world' }),
})
jest.mock('@/lib/api', () => ({
  apiClient: (...args: any[]) => mockApiClient(...args),
}))

import { requestPermissionsAsync } from 'expo-audio'
import * as FileSystem from 'expo-file-system'

describe('useVoiceInput', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    stateCounter = 0
    Object.keys(stateStore).forEach(k => delete stateStore[k])
    mockRecorderState.isRecording = false
    mockRecorderState.uri = 'file://recording.m4a'
  })

  function getHook() {
    stateCounter = 0
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { useVoiceInput } = require('@/hooks/useVoiceInput')
    return useVoiceInput()
  }

  it('startRecording calls requestPermissionsAsync and recorder.record', async () => {
    const hook = getHook()
    await hook.startRecording()

    expect(mockRequestPermissions).toHaveBeenCalled()
    expect(mockPrepareToRecordAsync).toHaveBeenCalled()
    expect(mockRecord).toHaveBeenCalled()
  })

  it('stopAndTranscribe stops recorder, reads file, sends to /api/audio/transcribe, returns transcript', async () => {
    const hook = getHook()
    const transcript = await hook.stopAndTranscribe()

    expect(mockStop).toHaveBeenCalled()
    expect(FileSystem.readAsStringAsync).toHaveBeenCalledWith(
      'file://recording.m4a',
      { encoding: 'base64' }
    )
    expect(mockApiClient).toHaveBeenCalledWith(
      '/api/audio/transcribe',
      expect.objectContaining({
        method: 'POST',
        headers: { 'Content-Type': 'audio/m4a' },
      })
    )
    expect(transcript).toBe('hello world')
  })

  it('isRecording reflects recorder state', () => {
    mockRecorderState.isRecording = false
    const hook = getHook()
    expect(hook.isRecording).toBe(false)
  })

  it('returns error string when transcription fails', async () => {
    mockApiClient.mockResolvedValueOnce({
      ok: false,
      json: () => Promise.resolve({ error: 'fail' }),
    })

    const hook = getHook()
    const transcript = await hook.stopAndTranscribe()

    expect(transcript).toBeNull()
    expect(hook.error).toBe('Could not transcribe audio. Try speaking again.')
  })
})
