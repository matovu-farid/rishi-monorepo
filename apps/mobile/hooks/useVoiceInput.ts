import { useState } from 'react'
// expo-audio renamed the recording-permission helper to
// `requestRecordingPermissionsAsync` in the SDK 54 line — the
// `requestPermissionsAsync` symbol used by older docs no longer exists.
// Use the recording-specific helper directly.
import {
  useAudioRecorder,
  RecordingPresets,
  requestRecordingPermissionsAsync,
} from 'expo-audio'
// SDK 54 moved `readAsStringAsync` + `EncodingType` to the /legacy subpath;
// the new File/Paths API doesn't expose a base64 read mode we can plumb
// through to the worker's audio transcription endpoint.
import * as FileSystem from 'expo-file-system/legacy'
import { Platform } from 'react-native'
import { apiClient } from '@/lib/api'

export function useVoiceInput() {
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY)
  const [isTranscribing, setIsTranscribing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [permissionDenied, setPermissionDenied] = useState(false)

  const startRecording = async () => {
    setError(null)
    // P1-Z: iOS shows the microphone permission sheet exactly once per
    // install. After the user taps "Don't Allow", every subsequent call
    // to `requestRecordingPermissionsAsync` resolves IMMEDIATELY with
    // `{ granted: false }` — the system never re-prompts. The only path
    // back is for the user to flip the toggle in
    // Settings → Privacy → Microphone → Rishi. We surface that path via
    // the "Open Settings" pressable in ChatInput which calls
    // `Linking.openSettings()`.
    //
    // Android shows the system prompt twice; on the third denial the OS
    // marks the permission as "Don't ask again" and behaves like iOS.
    const { granted } = await requestRecordingPermissionsAsync()
    if (!granted) {
      setPermissionDenied(true)
      return
    }
    setPermissionDenied(false)
    await recorder.prepareToRecordAsync()
    recorder.record()
  }

  const stopAndTranscribe = async (): Promise<string | null> => {
    await recorder.stop()
    const uri = recorder.uri
    if (!uri) {
      setError('Could not transcribe audio. Try speaking again.')
      return null
    }
    setIsTranscribing(true)
    try {
      const base64 = await FileSystem.readAsStringAsync(uri, {
        encoding: FileSystem.EncodingType.Base64,
      })
      const binaryString = atob(base64)
      const bytes = new Uint8Array(binaryString.length)
      for (let i = 0; i < binaryString.length; i++) {
        bytes[i] = binaryString.charCodeAt(i)
      }
      const contentType = Platform.OS === 'ios' ? 'audio/m4a' : 'audio/webm'
      const response = await apiClient('/api/audio/transcribe', {
        method: 'POST',
        headers: { 'Content-Type': contentType },
        body: bytes.buffer,
      })
      if (!response.ok) {
        setError('Could not transcribe audio. Try speaking again.')
        return null
      }
      const result = await response.json()
      return result.transcript || null
    } catch (_e) {
      setError('Could not transcribe audio. Try speaking again.')
      return null
    } finally {
      setIsTranscribing(false)
      // Clean up recording file
      if (uri) await FileSystem.deleteAsync(uri, { idempotent: true }).catch(() => {})
    }
  }

  return {
    startRecording,
    stopAndTranscribe,
    isRecording: recorder.isRecording,
    isTranscribing,
    error,
    permissionDenied,
  }
}
