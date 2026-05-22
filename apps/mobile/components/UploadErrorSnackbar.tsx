/**
 * Surface upload storage-cap errors as a non-blocking snackbar.
 *
 * The book-import upload pipeline runs outside the React tree. When
 * /upload-url returns 413/507 it calls `useUploadErrorStore.show(...)`;
 * this component subscribes to that store and renders the shared
 * UndoSnackbar primitive. We reuse UndoSnackbar (no "Undo" button — just
 * a dismissable bar) per the team's "no new lib for one-off UI" rule.
 *
 * STA-019: the snackbar now carries an actionable button when the notice
 * has an `action`. Tapping it routes to the Settings tab (manage-storage)
 * or the Library tab (manage-books) and dismisses the notice so the same
 * notice doesn't re-trigger the auto-dismiss timer in the background.
 */
import { useEffect } from 'react'
import { useRouter } from 'expo-router'
import { useUploadErrorStore } from '@/lib/sync/upload-error-store'
import type { UploadErrorActionKind } from '@/lib/sync/upload-error-store'
import { UndoSnackbar } from '@/components/UndoSnackbar'

// How long the bar stays visible before auto-dismissing. Tuned to match
// the existing UndoSnackbar duration so the visual pattern is consistent.
const AUTO_DISMISS_MS = 6_000

/**
 * Map an action kind to a route. Kept inline so we don't grow a new
 * navigation helper file for two destinations.
 */
function routeForAction(kind: UploadErrorActionKind): string {
  switch (kind) {
    case 'manage-storage':
      // Storage panel doesn't live on its own screen yet — Settings is the
      // closest entry point and the future home for storage controls.
      return '/(tabs)/settings'
    case 'manage-books':
      return '/(tabs)'
    default:
      return '/(tabs)/settings'
  }
}

export function UploadErrorSnackbar(): React.JSX.Element | null {
  const current = useUploadErrorStore((s) => s.current)
  const dismiss = useUploadErrorStore((s) => s.dismiss)
  const router = useRouter()

  useEffect(() => {
    if (!current) return
    const id = setTimeout(dismiss, AUTO_DISMISS_MS)
    return () => clearTimeout(id)
  }, [current, dismiss])

  if (!current) return null

  const action = current.action

  return (
    <UndoSnackbar
      visible={true}
      message={current.message}
      actionLabel={action?.label ?? null}
      onAction={() => {
        if (!action) return
        router.push(routeForAction(action.kind))
        dismiss()
      }}
      onDismiss={dismiss}
    />
  )
}
