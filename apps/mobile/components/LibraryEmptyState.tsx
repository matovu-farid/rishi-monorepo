import { View, type LayoutChangeEvent } from 'react-native'
import { EmptyState } from '@/components/ui/EmptyState'

interface LibraryEmptyStateProps {
  onImport: () => void
  importing: boolean
  /**
   * Forwarded onto the Import button — used by the onboarding tour
   * (G28) to register the button's layout with the target registry.
   */
  importButtonProps?: { onLayout?: (event: LayoutChangeEvent) => void }
  /** Forwarded onto the outer container, again for the tour overlay. */
  containerProps?: { onLayout?: (event: LayoutChangeEvent) => void }
}

/**
 * Library empty state (P1-U).
 *
 * Re-implemented on top of the shared `EmptyState` primitive so the
 * accent color, pill button radius, and 44pt hit target are sourced
 * from the design tokens (colors.accent.primary, radius.full). The
 * wrapping View exists so we can preserve the `library-empty-state`
 * Detox testID and forward the onboarding tour's `onLayout` callbacks
 * without modifying the shared primitive.
 */
export function LibraryEmptyState({
  onImport,
  importing,
  importButtonProps,
  containerProps,
}: LibraryEmptyStateProps) {
  return (
    <View
      testID="library-empty-state"
      style={{ flex: 1 }}
      onLayout={(event) => {
        containerProps?.onLayout?.(event)
        // The Import button also wants to be a tour target; forwarding
        // the container layout is the closest approximation since the
        // EmptyState primitive owns the button itself.
        importButtonProps?.onLayout?.(event)
      }}
    >
      <EmptyState
        testID="library-empty-state-inner"
        titleTestID="library-empty-title"
        icon="book-outline"
        title="No books yet"
        description="Import an EPUB or PDF from your device to start reading."
        action={{
          label: 'Import Book',
          onPress: onImport,
          testID: 'library-empty-import-btn',
          disabled: importing,
        }}
      />
    </View>
  )
}
