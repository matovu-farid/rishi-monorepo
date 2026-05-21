import { View, Text, TouchableOpacity, ActivityIndicator, type LayoutChangeEvent } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'

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

export function LibraryEmptyState({
  onImport,
  importing,
  importButtonProps,
  containerProps,
}: LibraryEmptyStateProps) {
  return (
    <View
      className="flex-1 items-center justify-center px-6"
      onLayout={containerProps?.onLayout}
    >
      <IconSymbol name="book.fill" size={48} color="#9BA1A6" />
      <Text className="text-xl font-semibold text-gray-900 dark:text-white mt-4">
        No books yet
      </Text>
      <Text className="text-base text-gray-500 dark:text-gray-400 text-center mt-2 mb-6">
        Import an EPUB or PDF from your device to start reading.
      </Text>
      <TouchableOpacity
        className="w-full bg-[#0a7ea4] rounded-lg py-3 items-center"
        onPress={onImport}
        disabled={importing}
        accessibilityRole="button"
        accessibilityLabel="Import Book"
        onLayout={importButtonProps?.onLayout}
      >
        {importing ? (
          <ActivityIndicator color="#FFFFFF" />
        ) : (
          <Text className="text-white font-semibold text-base">Import Book</Text>
        )}
      </TouchableOpacity>
    </View>
  )
}
