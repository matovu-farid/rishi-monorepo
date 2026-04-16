import { Text, View } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface EmbeddingProgressProps {
  bookTitle: string
  progress: number
  totalChunks: number
  processedChunks: number
}

export function EmbeddingProgress({
  bookTitle,
  progress,
  totalChunks,
  processedChunks,
}: EmbeddingProgressProps) {
  const percent = Math.round(progress * 100)

  return (
    <View
      className="bg-gray-50 dark:bg-[#1E2022] rounded-xl p-4 mx-4"
      accessibilityLabel={`Preparing book for AI, ${percent} percent complete`}
    >
      <IconSymbol name="sparkles" size={24} color="#0a7ea4" />

      <Text className="text-base font-semibold text-gray-900 dark:text-gray-100 mt-2">
        Preparing &ldquo;{bookTitle}&rdquo; for AI...
      </Text>

      {/* Progress bar */}
      <View className="h-2 bg-gray-200 dark:bg-gray-700 rounded-full mt-3 overflow-hidden">
        <View
          className="h-full bg-[#0a7ea4] rounded-full"
          style={{ width: `${percent}%` }}
        />
      </View>

      <Text className="text-sm text-gray-500 dark:text-gray-400 mt-2">
        Embedding {processedChunks} of {totalChunks} passages
      </Text>
    </View>
  )
}
