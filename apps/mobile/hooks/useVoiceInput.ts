import { useState } from 'react'
import { useAudioRecorder, RecordingPresets, requestPermissionsAsync } from 'expo-audio'
import * as FileSystem from 'expo-file-system'
import { Platform } from 'react-native'
import { apiClient } from '@/lib/api'

export function useVoiceInput() {
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY)
  const [isTranscribing, setIsTranscribing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [permissionDenied, setPermissionDenied] = useState(false)

  const startRecording = async () => {
    setError(null)
    const { granted } = await requestPermissionsAsync()
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
