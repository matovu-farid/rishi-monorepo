/**
 * Surface upload storage-cap errors as a non-blocking snackbar.
 *
 * The book-import upload pipeline runs outside the React tree. When
 * /upload-url returns 413/507 it calls `useUploadErrorStore.show(...)`;
 * this component subscribes to that store and renders the shared
 * UndoSnackbar primitive. We reuse UndoSnackbar (no "Undo" button — just
 * a dismissable bar) per the team's "no new lib for one-off UI" rule.
 */
import { useEffect } from 'react'
import { useUploadErrorStore } from '@/lib/sync/upload-error-store'
import { UndoSnackbar } from '@/components/UndoSnackbar'

// How long the bar stays visible before auto-dismissing. Tuned to match
// the existing UndoSnackbar duration so the visual pattern is consistent.
const AUTO_DISMISS_MS = 6_000

export function UploadErrorSnackbar(): React.JSX.Element | null {
  const current = useUploadErrorStore((s) => s.current)
  const dismiss = useUploadErrorStore((s) => s.dismiss)

  useEffect(() => {
    if (!current) return
    const id = setTimeout(dismiss, AUTO_DISMISS_MS)
    return () => clearTimeout(id)
  }, [current, dismiss])

  if (!current) return null

  return (
    <UndoSnackbar
      visible={true}
      message={current.message}
      actionLabel={null}
      onAction={() => {
        /* no action — this is a passive notification */
      }}
      onDismiss={dismiss}
    />
  )
}
