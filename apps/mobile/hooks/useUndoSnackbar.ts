/**
 * In-house snackbar with an "Undo" action (G10).
 *
 * Used after destructive actions (highlight delete is the first caller)
 * so the user gets a 5s window to revert. Mirrors electron's
 * `useUndoableHighlightShortcut` semantics but with RN-native primitives
 * — no keyboard binding because mobile has no Cmd-Z.
 *
 * The state is local to the consuming reader screen. The hook returns
 * `{ visible, message, actionLabel, show, action, dismiss }`. The
 * consumer renders `<UndoSnackbar />` reading from this state and wires
 * the snackbar's button to `action()`.
 */
import { useCallback, useRef, useState } from 'react'

export const UNDO_SNACKBAR_DURATION_MS = 5_000

export interface UndoSnackbarState {
  visible: boolean
  message: string | null
  actionLabel: string | null
  show: (message: string, actionLabel: string, onAction: () => void) => void
  action: () => void
  dismiss: () => void
}

export function useUndoSnackbar(): UndoSnackbarState {
  const [visible, setVisible] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [actionLabel, setActionLabel] = useState<string | null>(null)
  const handlerRef = useRef<(() => void) | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
  }, [])

  const dismiss = useCallback(() => {
    clearTimer()
    handlerRef.current = null
    setVisible(false)
  }, [clearTimer])

  const show = useCallback(
    (newMessage: string, newActionLabel: string, onAction: () => void) => {
      clearTimer()
      handlerRef.current = onAction
      setMessage(newMessage)
      setActionLabel(newActionLabel)
      setVisible(true)
      timerRef.current = setTimeout(() => {
        handlerRef.current = null
        setVisible(false)
      }, UNDO_SNACKBAR_DURATION_MS)
    },
    [clearTimer],
  )

  const action = useCallback(() => {
    const handler = handlerRef.current
    if (!handler) return
    clearTimer()
    handlerRef.current = null
    setVisible(false)
    handler()
  }, [clearTimer])

  return { visible, message, actionLabel, show, action, dismiss }
}
