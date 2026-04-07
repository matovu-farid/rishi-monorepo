import { useState, useCallback, useRef } from 'react'
import { Alert } from 'react-native'
import { createRealtimeSession, closeRealtimeSession } from '@/lib/realtime/session'
import type { RealtimeStatus, RealtimeSessionHandle } from '@/lib/realtime/types'

export function useRealtimeChat(bookId: string) {
  const [status, setStatus] = useState<RealtimeStatus>('idle')
  const [showGuardrailWarning, setShowGuardrailWarning] = useState(false)
  const sessionRef = useRef<RealtimeSessionHandle | null>(null)

  const start = useCallback(async () => {
    if (status !== 'idle') return
    setStatus('connecting')
    try {
      const handle = await createRealtimeSession({
        bookId,
        onGuardrailTriggered: () => {
          setShowGuardrailWarning(true)
          setTimeout(() => setShowGuardrailWarning(false), 4000)
        },
        onSessionEnded: () => {
          setStatus('idle')
          sessionRef.current = null
        },
        onError: (error) => {
          Alert.alert(
            'Voice Chat Error',
            error.message ?? 'Could not connect to voice chat. Check your internet connection and try again.'
          )
          setStatus('idle')
          sessionRef.current = null
        },
        onStatusChange: (newStatus) => {
          setStatus(newStatus)
        },
      })
      sessionRef.current = handle
      setStatus('active')
    } catch (error) {
      Alert.alert(
        'Connection Failed',
        'Could not connect to voice chat. Check your internet connection and try again.'
      )
      setStatus('idle')
    }
  }, [bookId, status])

  const stop = useCallback(() => {
    if (status === 'idle' || status === 'connecting') return
    setStatus('ending')
    closeRealtimeSession()
    sessionRef.current = null
    // Small delay for ending animation before resetting to idle
    setTimeout(() => setStatus('idle'), 500)
  }, [status])

  const toggle = useCallback(() => {
    if (status === 'idle') {
      start()
    } else if (status === 'active' || status === 'speaking') {
      stop()
    }
  }, [status, start, stop])

  return {
    status,
    showGuardrailWarning,
    toggle,
    isActive: status === 'active' || status === 'speaking',
  }
}
