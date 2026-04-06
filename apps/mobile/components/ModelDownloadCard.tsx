import { Text, TouchableOpacity, View } from 'react-native'
import { IconSymbol } from '@/components/ui/icon-symbol'

interface ModelDownloadCardProps {
  downloadProgress: number
  isDownloading: boolean
  onDownload: () => void
}

export function ModelDownloadCard({
  downloadProgress,
  isDownloading,
  onDownload,
}: ModelDownloadCardProps) {
  const percent = Math.round(downloadProgress * 100)

  return (
    <View
      className="bg-gray-50 dark:bg-[#1E2022] rounded-xl p-8 mx-4 items-center"
      accessibilityRole="alert"
    >
      <IconSymbol name="arrow.down.circle" size={40} color="#687076" />

      <Text className="text-lg font-semibold text-gray-900 dark:text-gray-100 mt-4 text-center">
        AI Model Required
      </Text>

      <Text className="text-base text-gray-500 dark:text-gray-400 mt-2 text-center">
        Download the AI model (80 MB) to ask questions about your books.
      </Text>

      {isDownloading ? (
        <View className="w-full mt-6 mx-8">
          <View className="h-2 bg-gray-200 dark:bg-gray-700 rounded-full overflow-hidden">
            <View
              className="h-full bg-[#0a7ea4] rounded-full"
              style={{ width: `${percent}%` }}
            />
          </View>
          <Text className="text-sm text-gray-500 dark:text-gray-400 mt-2 text-center">
            {percent}%
          </Text>
        </View>
      ) : (
        <TouchableOpacity
          onPress={onDownload}
          className="bg-[#0a7ea4] rounded-lg h-11 items-center justify-center mt-6 w-full mx-8"
          accessibilityLabel="Download AI model, 80 megabytes"
          accessibilityRole="button"
        >
          <Text className="text-white text-base font-semibold">
            Download Model
          </Text>
        </TouchableOpacity>
      )}
    </View>
  )
}
