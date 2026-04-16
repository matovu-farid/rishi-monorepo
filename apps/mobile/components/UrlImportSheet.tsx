import { useCallback, useRef, useState } from 'react'
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ActivityIndicator,
  Keyboard,
} from 'react-native'
import { Book } from '@/types/book'
import { importBookFromUrl } from '@/lib/file-import'

interface UrlImportSheetProps {
  visible: boolean
  onDismiss: () => void
  onImported: (book: Book) => void
}

export function UrlImportSheet({ visible, onDismiss, onImported }: UrlImportSheetProps) {
  const [status, setStatus] = useState<'idle' | 'downloading' | 'error'>('idle')
  const [errorMessage, setErrorMessage] = useState('')
  const inputRef = useRef<TextInput>(null)
  // Track URL in both ref (for native input) and state (for user typing)
  const urlRef = useRef('')

  const handleDownload = useCallback(async (textOverride?: string) => {
    const trimmed = (textOverride ?? urlRef.current).trim()
    if (!trimmed) return

    Keyboard.dismiss()
    setStatus('downloading')
    setErrorMessage('')

    try {
      const book = await importBookFromUrl(trimmed)
      urlRef.current = ''
      inputRef.current?.clear()
      setStatus('idle')
      onDismiss()
      onImported(book)
    } catch (err: any) {
      setStatus('error')
      setErrorMessage(err.message || 'Could not download file. Check the URL and try again.')
    }
  }, [onDismiss, onImported])

  const handleClose = useCallback(() => {
    if (status === 'downloading') return
    urlRef.current = ''
    inputRef.current?.clear()
    setStatus('idle')
    setErrorMessage('')
    onDismiss()
  }, [status, onDismiss])

  if (!visible) return null

  return (
    <View className="absolute inset-0 bg-black/40 justify-end">
      <TouchableOpacity
        activeOpacity={1}
        className="flex-1"
        onPress={handleClose}
      />
      <View className="bg-white dark:bg-gray-900 rounded-t-2xl">
        <View className="w-10 h-1 bg-gray-300 rounded-full self-center mt-3 mb-2" />
        <View className="px-6 pt-2 pb-8">
          <Text testID="url-import-title" className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
            Import from URL
          </Text>

          <TextInput
            ref={inputRef}
            testID="url-input"
            className="border border-gray-300 dark:border-gray-600 rounded-lg px-4 py-3 mb-4 text-gray-900 dark:text-white bg-white dark:bg-gray-800"
            placeholder="https://example.com/book.epub (or .pdf, .mobi, .djvu)"
            placeholderTextColor="#9CA3AF"
            defaultValue=""
            onChangeText={(text) => { urlRef.current = text }}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            editable={status !== 'downloading'}
            onSubmitEditing={(e) => handleDownload(e.nativeEvent.text)}
          />

          {status === 'error' && errorMessage ? (
            <Text testID="url-import-error" className="text-red-500 text-sm mb-3">
              {errorMessage}
            </Text>
          ) : null}

          <TouchableOpacity
            testID="url-download-button"
            className="rounded-lg py-3 items-center bg-[#0a7ea4]"
            onPress={handleDownload}
            disabled={status === 'downloading'}
          >
            {status === 'downloading' ? (
              <View className="flex-row items-center gap-2">
                <ActivityIndicator color="#FFFFFF" size="small" />
                <Text className="text-white font-semibold">Downloading...</Text>
              </View>
            ) : (
              <Text className="text-white font-semibold">
                Download
              </Text>
            )}
          </TouchableOpacity>
        </View>
      </View>
    </View>
  )
}
