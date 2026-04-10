import { useCallback, useRef, useState } from 'react'
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ActivityIndicator,
  Keyboard,
} from 'react-native'
import BottomSheet from '@gorhom/bottom-sheet'
import { Book } from '@/types/book'
import { importBookFromUrl } from '@/lib/file-import'

interface UrlImportSheetProps {
  sheetRef: React.RefObject<BottomSheet | null>
  onImported: (book: Book) => void
}

export function UrlImportSheet({ sheetRef, onImported }: UrlImportSheetProps) {
  const [url, setUrl] = useState('')
  const [status, setStatus] = useState<'idle' | 'downloading' | 'error'>('idle')
  const [errorMessage, setErrorMessage] = useState('')
  const inputRef = useRef<TextInput>(null)

  const handleDownload = useCallback(async () => {
    const trimmed = url.trim()
    if (!trimmed) return

    Keyboard.dismiss()
    setStatus('downloading')
    setErrorMessage('')

    try {
      const book = await importBookFromUrl(trimmed)
      setUrl('')
      setStatus('idle')
      sheetRef.current?.close()
      onImported(book)
    } catch (err: any) {
      setStatus('error')
      setErrorMessage(err.message || 'Could not download file. Check the URL and try again.')
    }
  }, [url, sheetRef, onImported])

  const handleSheetChange = useCallback((index: number) => {
    if (index === -1) {
      setUrl('')
      setStatus('idle')
      setErrorMessage('')
    }
  }, [])

  const canDownload = url.trim().length > 0 && status !== 'downloading'

  return (
    <BottomSheet
      ref={sheetRef}
      index={-1}
      snapPoints={[320]}
      enablePanDownToClose
      onChange={handleSheetChange}
      backgroundStyle={{ backgroundColor: '#FFFFFF' }}
      handleIndicatorStyle={{ backgroundColor: '#D1D5DB' }}
    >
      <View className="px-6 pt-2 pb-6">
        <Text className="text-lg font-semibold text-gray-900 mb-4">
          Import from URL
        </Text>

        <TextInput
          ref={inputRef}
          testID="url-input"
          className="border border-gray-300 rounded-lg px-4 py-3 mb-4 text-gray-900 bg-white"
          placeholder="https://example.com/book.epub"
          placeholderTextColor="#9CA3AF"
          value={url}
          onChangeText={setUrl}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          editable={status !== 'downloading'}
        />

        {status === 'error' && errorMessage ? (
          <Text testID="url-import-error" className="text-red-500 text-sm mb-3">
            {errorMessage}
          </Text>
        ) : null}

        <TouchableOpacity
          testID="url-download-button"
          className={`rounded-lg py-3 items-center ${canDownload ? 'bg-[#0a7ea4]' : 'bg-gray-300'}`}
          onPress={handleDownload}
          disabled={!canDownload}
        >
          {status === 'downloading' ? (
            <View className="flex-row items-center gap-2">
              <ActivityIndicator color="#FFFFFF" size="small" />
              <Text className="text-white font-semibold">Downloading...</Text>
            </View>
          ) : (
            <Text className={`font-semibold ${canDownload ? 'text-white' : 'text-gray-500'}`}>
              Download
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </BottomSheet>
  )
}
