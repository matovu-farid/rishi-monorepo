import { useCallback, useState } from 'react'
import * as LegacyFS from 'expo-file-system/legacy'

// SDK 54 made the top-level `expo-file-system` legacy methods throw at runtime,
// which breaks `@epubjs-react-native/expo-file-system@1.1.4`. This adapter
// mirrors that hook's shape but routes calls through `expo-file-system/legacy`,
// which still has working implementations.
export function useFileSystem() {
  const [file, setFile] = useState<string | null>(null)
  const [progress, setProgress] = useState(0)
  const [downloading, setDownloading] = useState(false)
  const [size, setSize] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  const downloadFile = useCallback(async (fromUrl: string, toFile: string) => {
    const callback = (p: { totalBytesWritten: number; totalBytesExpectedToWrite: number }) => {
      const current = Math.round((p.totalBytesWritten / p.totalBytesExpectedToWrite) * 100)
      setProgress(current)
    }
    const task = LegacyFS.createDownloadResumable(
      fromUrl,
      LegacyFS.documentDirectory + toFile,
      { cache: true },
      callback,
    )
    setDownloading(true)
    try {
      const value = await task.downloadAsync()
      if (!value) throw new Error('Download failed')
      const contentLength = value.headers?.['Content-Length']
      if (contentLength) setSize(Number(contentLength))
      setSuccess(true)
      setError(null)
      setFile(value.uri)
      return { uri: value.uri, mimeType: value.mimeType }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Error downloading file')
      return { uri: null, mimeType: null }
    } finally {
      setDownloading(false)
    }
  }, [])

  const getFileInfo = useCallback(async (fileUri: string) => {
    const info = await LegacyFS.getInfoAsync(fileUri)
    return {
      uri: info.uri,
      exists: info.exists,
      isDirectory: 'isDirectory' in info ? info.isDirectory : false,
      size: 'size' in info ? info.size : undefined,
    }
  }, [])

  return {
    file,
    progress,
    downloading,
    size,
    error,
    success,
    documentDirectory: LegacyFS.documentDirectory,
    cacheDirectory: LegacyFS.cacheDirectory,
    bundleDirectory: LegacyFS.bundleDirectory || undefined,
    readAsStringAsync: LegacyFS.readAsStringAsync,
    writeAsStringAsync: LegacyFS.writeAsStringAsync,
    deleteAsync: LegacyFS.deleteAsync,
    downloadFile,
    getFileInfo,
  }
}
