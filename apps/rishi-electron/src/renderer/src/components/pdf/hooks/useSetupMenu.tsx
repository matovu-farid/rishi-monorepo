import { useEffect } from 'react'
import { usePdfStore } from '@/stores/pdfStore'

/**
 * Electron equivalent of the Tauri useSetupMenu hook.
 * Since Electron doesn't expose the native menu API to the renderer,
 * we register a keyboard shortcut to toggle dual-page view instead.
 */
export function useSetupMenu() {
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Cmd/Ctrl + Shift + T to toggle two-page view
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'T') {
        e.preventDefault()
        const current = usePdfStore.getState().isDualPage
        usePdfStore.getState().setDualPage(!current)
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => {
      window.removeEventListener('keydown', handleKeyDown)
    }
  }, [])
}
