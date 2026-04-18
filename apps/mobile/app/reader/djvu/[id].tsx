import { useCallback, useEffect, useRef, useState } from 'react'
import {
  View,
  Text,
  TouchableOpacity,
  AppState,
  AppStateStatus,
  ActivityIndicator,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useLocalSearchParams, useRouter } from 'expo-router'
import { WebView } from 'react-native-webview'
import { File as ExpoFile } from 'expo-file-system'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { getBookForReading, updateBookPage } from '@/lib/book-storage'
import { Book } from '@/types/book'

/**
 * DJVU reader using djvu.js — a pure JavaScript DJVU decoder.
 * The library is loaded from a CDN inside the WebView.
 * Pages are rendered to a <canvas> element.
 */
const DJVU_VIEWER_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=yes"/>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #1a1a1a;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-start;
    min-height: 100vh;
    padding: 16px 0 80px;
    overflow: auto;
  }
  canvas {
    max-width: 100%;
    height: auto;
    box-shadow: 0 2px 20px rgba(0,0,0,0.5);
  }
  .loading, .error {
    color: #aaa;
    font-family: -apple-system, sans-serif;
    font-size: 16px;
    text-align: center;
    padding: 40px 20px;
  }
  .error { color: #e55; }
</style>
</head>
<body>
<div class="loading" id="status">Loading DJVU viewer...</div>
<canvas id="canvas" style="display:none"></canvas>
<script src="https://cdn.jsdelivr.net/npm/djvu.js@0.5.2/dist/djvu.js"></script>
<script>
var djvuDoc = null;
var pageCount = 0;
var currentPage = 1;

function renderPage(pageNum) {
  if (!djvuDoc || pageNum < 1 || pageNum > pageCount) return;
  currentPage = pageNum;

  try {
    var page = djvuDoc.getPage(pageNum);
    var imageData = page.getImageData();

    var canvas = document.getElementById('canvas');
    canvas.width = imageData.width;
    canvas.height = imageData.height;
    var ctx = canvas.getContext('2d');
    ctx.putImageData(imageData, 0, 0);

    canvas.style.display = 'block';
    document.getElementById('status').style.display = 'none';

    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'page',
      current: currentPage,
      total: pageCount
    }));
  } catch (e) {
    document.getElementById('status').className = 'error';
    document.getElementById('status').textContent = 'Failed to render page ' + pageNum + ': ' + e.message;
    document.getElementById('status').style.display = 'block';
  }
}

function loadBook(base64) {
  try {
    document.getElementById('status').textContent = 'Decoding DJVU...';
    document.getElementById('status').style.display = 'block';

    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

    var buffer = bytes.buffer;
    djvuDoc = new DjVu.Document(buffer);
    pageCount = djvuDoc.getPageCount();

    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'loaded',
      total: pageCount
    }));
  } catch (e) {
    document.getElementById('status').className = 'error';
    document.getElementById('status').textContent = 'Failed to parse DJVU: ' + e.message;
    document.getElementById('status').style.display = 'block';
    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'error',
      message: e.message
    }));
  }
}

// Listen for messages from RN
document.addEventListener('message', function(e) {
  var msg = JSON.parse(e.data);
  if (msg.type === 'load') loadBook(msg.data);
  if (msg.type === 'goto') renderPage(msg.page);
});
window.addEventListener('message', function(e) {
  var msg = JSON.parse(e.data);
  if (msg.type === 'load') loadBook(msg.data);
  if (msg.type === 'goto') renderPage(msg.page);
});
</script>
</body>
</html>`

export default function DjvuReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()

  const [book, setBook] = useState<Book | null>(null)
  const [loading, setLoading] = useState(true)
  const [pageCount, setPageCount] = useState(0)
  const [currentPage, setCurrentPage] = useState(1)
  const [toolbarVisible, setToolbarVisible] = useState(false)
  const [bookLoaded, setBookLoaded] = useState(false)
  const [zoom, setZoom] = useState(100)

  const webViewRef = useRef<WebView>(null)
  const currentPageRef = useRef(1)
  const toolbarTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Load book from DB
  useEffect(() => {
    if (id) {
      setLoading(true)
      getBookForReading(id)
        .then((loaded) => {
          if (loaded) {
            setBook(loaded)
            const startPage = loaded.currentPage || 1
            setCurrentPage(startPage)
            currentPageRef.current = startPage
          }
        })
        .catch((err) => console.error('Failed to load book for reading:', err))
        .finally(() => setLoading(false))
    }
  }, [id])

  // Send file data to WebView once djvu.js is loaded
  useEffect(() => {
    if (!book || !bookLoaded) return

    const file = new ExpoFile(book.filePath)
    file.base64().then((base64) => {
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'load', data: base64 })
      )
    })
  }, [book, bookLoaded])

  // Save position on app background
  useEffect(() => {
    const handleAppStateChange = (nextState: AppStateStatus) => {
      if (nextState === 'background' || nextState === 'inactive') {
        if (book?.id) {
          updateBookPage(book.id, currentPageRef.current)
        }
      }
    }
    const sub = AppState.addEventListener('change', handleAppStateChange)
    return () => sub.remove()
  }, [book?.id])

  // Auto-hide toolbar
  useEffect(() => {
    if (toolbarVisible) {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
      toolbarTimerRef.current = setTimeout(() => setToolbarVisible(false), 3000)
    }
    return () => {
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current)
    }
  }, [toolbarVisible])

  const handleMessage = useCallback(
    (event: { nativeEvent: { data: string } }) => {
      const msg = JSON.parse(event.nativeEvent.data)
      if (msg.type === 'loaded') {
        setPageCount(msg.total)
        // Render the saved page
        webViewRef.current?.postMessage(
          JSON.stringify({ type: 'goto', page: currentPageRef.current })
        )
      } else if (msg.type === 'page') {
        setCurrentPage(msg.current)
        currentPageRef.current = msg.current
        if (book?.id) {
          updateBookPage(book.id, msg.current)
        }
      }
    },
    [book?.id]
  )

  const handleBack = useCallback(() => {
    if (book?.id) {
      updateBookPage(book.id, currentPageRef.current)
    }
    router.back()
  }, [book?.id, router])

  const handlePrevPage = useCallback(() => {
    if (currentPageRef.current > 1) {
      const next = currentPageRef.current - 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', page: next })
      )
    }
  }, [])

  const handleNextPage = useCallback(() => {
    if (currentPageRef.current < pageCount) {
      const next = currentPageRef.current + 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', page: next })
      )
    }
  }, [pageCount])

  const handleZoomIn = useCallback(() => {
    setZoom(prev => Math.min(prev + 25, 300))
  }, [])

  const handleZoomOut = useCallback(() => {
    setZoom(prev => Math.max(prev - 25, 50))
  }, [])

  // Send zoom level to WebView when it changes
  useEffect(() => {
    webViewRef.current?.injectJavaScript(`
      document.getElementById('canvas').style.transform = 'scale(${zoom / 100})';
      document.getElementById('canvas').style.transformOrigin = 'top center';
      true;
    `)
  }, [zoom])

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: '#1a1a1a', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" color="#aaa" />
        <Text style={{ marginTop: 12, color: '#aaa' }}>Loading book...</Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    return (
      <View style={{ flex: 1, backgroundColor: '#1a1a1a', justifyContent: 'center', alignItems: 'center' }}>
        <Text style={{ color: '#aaa', fontSize: 16 }}>Book file not available</Text>
      </View>
    )
  }

  return (
    <View style={{ flex: 1, backgroundColor: '#1a1a1a' }}>
      <WebView
        ref={webViewRef}
        source={{ html: DJVU_VIEWER_HTML }}
        originWhitelist={['*']}
        onMessage={handleMessage}
        onLoadEnd={() => setBookLoaded(true)}
        style={{ flex: 1 }}
        javaScriptEnabled={true}
        allowsInlineMediaPlayback={true}
        onShouldStartLoadWithRequest={(request) => {
          // Allow CDN load for djvu.js and the initial HTML
          if (
            request.url.startsWith('about:') ||
            request.url.startsWith('data:') ||
            request.url.includes('cdn.jsdelivr.net')
          ) {
            return true
          }
          return false
        }}
      />

      {/* Top toolbar */}
      {toolbarVisible && (
        <SafeAreaView
          edges={['top']}
          style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            backgroundColor: 'rgba(0,0,0,0.8)',
          }}
        >
          <View
            style={{
              flexDirection: 'row',
              alignItems: 'center',
              paddingHorizontal: 12,
              paddingVertical: 10,
            }}
          >
            <TouchableOpacity
              onPress={handleBack}
              hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
              style={{ width: 44, height: 44, justifyContent: 'center', alignItems: 'center' }}
            >
              <IconSymbol name="chevron.left" size={24} color="#fff" />
            </TouchableOpacity>

            <Text
              numberOfLines={1}
              style={{
                flex: 1,
                color: '#fff',
                fontSize: 16,
                fontWeight: '600',
                textAlign: 'center',
                marginHorizontal: 8,
              }}
            >
              {book.title}
            </Text>

            <Text style={{ color: '#fff', fontSize: 13, minWidth: 70, textAlign: 'right' }}>
              {pageCount > 0
                ? `Page ${currentPage} / ${pageCount}`
                : '...'}
            </Text>
          </View>
        </SafeAreaView>
      )}

      {/* Bottom navigation bar */}
      {toolbarVisible && (
        <SafeAreaView
          edges={['bottom']}
          style={{
            position: 'absolute',
            bottom: 0,
            left: 0,
            right: 0,
            backgroundColor: 'rgba(0,0,0,0.8)',
          }}
        >
          <View
            style={{
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'center',
              paddingVertical: 10,
              gap: 24,
            }}
          >
            <TouchableOpacity
              onPress={handleZoomOut}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: zoom <= 50 ? 0.3 : 1,
              }}
              disabled={zoom <= 50}
            >
              <IconSymbol name="minus.magnifyingglass" size={22} color="#fff" />
            </TouchableOpacity>

            <Text style={{ color: '#fff', fontSize: 13, minWidth: 40, textAlign: 'center' }}>
              {zoom}%
            </Text>

            <TouchableOpacity
              onPress={handleZoomIn}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: zoom >= 300 ? 0.3 : 1,
              }}
              disabled={zoom >= 300}
            >
              <IconSymbol name="plus.magnifyingglass" size={22} color="#fff" />
            </TouchableOpacity>

            {/* separator */}
            <View style={{ width: 1, height: 24, backgroundColor: 'rgba(255,255,255,0.3)' }} />

            <TouchableOpacity
              onPress={handlePrevPage}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: currentPage <= 1 ? 0.3 : 1,
              }}
              disabled={currentPage <= 1}
            >
              <IconSymbol name="chevron.left" size={28} color="#fff" />
            </TouchableOpacity>

            <Text style={{ color: '#fff', fontSize: 16, fontWeight: '500' }}>
              {pageCount > 0
                ? `${currentPage} / ${pageCount}`
                : '...'}
            </Text>

            <TouchableOpacity
              onPress={handleNextPage}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: currentPage >= pageCount ? 0.3 : 1,
              }}
              disabled={currentPage >= pageCount}
            >
              <IconSymbol name="chevron.right" size={28} color="#fff" />
            </TouchableOpacity>
          </View>
        </SafeAreaView>
      )}

      {/* Invisible tap target to toggle toolbar */}
      <TouchableOpacity
        activeOpacity={1}
        onPress={() => setToolbarVisible((prev) => !prev)}
        style={{
          position: 'absolute',
          top: '30%',
          left: '20%',
          width: '60%',
          height: '40%',
        }}
      />
    </View>
  )
}
