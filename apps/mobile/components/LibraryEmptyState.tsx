import { View, Text, TouchableOpacity, ActivityIndicator } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface LibraryEmptyStateProps {
  onImport: () => void
  importing: boolean
}

export function LibraryEmptyState({ onImport, importing }: LibraryEmptyStateProps) {
  return (
    <View className="flex-1 items-center justify-center px-6">
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
