import { createContext } from 'react'

/**
 * Shared context exposed by ReaderShell.
 *
 * Lifted into its own module so consumers (ReaderBottomBar, ReaderOverlay,
 * the per-format reader screens) can import the context type without
 * pulling in `ReaderShell.tsx` itself — which transitively imports
 * `expo-blur` and other native-only modules through ReaderOverlay /
 * Toolbar. The jest tests for ReaderBottomBar mock those deps but cannot
 * follow the import chain through ReaderShell.
 */
export interface ReaderShellContextValue {
  bottomBarVisible: boolean
  toggleToolbar: () => void
  /**
   * RDR-025 — re-arm the 3s auto-hide timer without flipping visibility.
   * Called from the bottom bar's `onTouchStart` so users who hold their
   * finger on the chapter label / progress pill / icon cluster don't
   * lose the chrome under them.
   */
  interact: () => void
}

export const ReaderShellContext = createContext<ReaderShellContextValue>({
  bottomBarVisible: false,
  toggleToolbar: () => undefined,
  interact: () => undefined,
})
