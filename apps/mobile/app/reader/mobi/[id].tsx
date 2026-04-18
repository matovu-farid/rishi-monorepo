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
 * Minimal inline MOBI parser running inside a WebView.
 *
 * MOBI/PalmDOC format overview:
 * - PDB header (78 bytes) contains record offsets
 * - Record 0 is the MOBI header with metadata
 * - Records 1..N contain PalmDOC-compressed HTML
 * - Compression type 1 = none, type 2 = PalmDOC LZ77
 *
 * We extract the HTML, split by <mbp:pagebreak/> into chapters,
 * and render the current chapter. Navigation is handled by RN.
 */
const MOBI_PARSER_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=yes"/>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 18px;
    line-height: 1.7;
    padding: 16px 20px 80px;
    color: #1a1a1a;
    background: #fafaf8;
    word-wrap: break-word;
    overflow-wrap: break-word;
  }
  img { max-width: 100%; height: auto; }
  a { color: #0a7ea4; }
  h1, h2, h3 { margin: 1em 0 0.5em; }
  p { margin: 0.5em 0; }
  .loading { display: flex; align-items: center; justify-content: center; height: 80vh; color: #666; font-size: 16px; }
  .error { color: #c00; padding: 20px; text-align: center; }
</style>
</head>
<body>
<div class="loading" id="status">Parsing MOBI file...</div>
<div id="content" style="display:none"></div>
<script>
// PalmDOC decompression (LZ77 variant)
function decompressPalmDOC(data) {
  var out = [];
  var i = 0;
  while (i < data.length) {
    var c = data[i++];
    if (c === 0) {
      out.push(0);
    } else if (c >= 1 && c <= 8) {
      for (var j = 0; j < c && i < data.length; j++) {
        out.push(data[i++]);
      }
    } else if (c >= 9 && c <= 0x7F) {
      out.push(c);
    } else if (c >= 0x80 && c <= 0xBF) {
      if (i >= data.length) break;
      var next = data[i++];
      var dist = ((c << 8) | next) >> 3 & 0x7FF;
      var len = (next & 0x07) + 3;
      for (var k = 0; k < len; k++) {
        if (out.length - dist >= 0) {
          out.push(out[out.length - dist]);
        } else {
          out.push(0);
        }
      }
    } else {
      // c >= 0xC0: space + (c ^ 0x80)
      out.push(32);
      out.push(c ^ 0x80);
    }
  }
  return new Uint8Array(out);
}

function parseMobi(buf) {
  var view = new DataView(buf);

  // PDB header: numRecords at offset 76
  var numRecords = view.getUint16(76, false);

  // Record info list starts at offset 78, each entry is 8 bytes
  var recordOffsets = [];
  for (var r = 0; r < numRecords; r++) {
    recordOffsets.push(view.getUint32(78 + r * 8, false));
  }

  // Record 0 is the MOBI/PalmDOC header
  var rec0Start = recordOffsets[0];
  var compression = view.getUint16(rec0Start, false); // 1=none, 2=PalmDOC
  var textRecordCount = view.getUint16(rec0Start + 8, false);

  // Extract and decompress text records
  var allBytes = [];
  for (var i = 1; i <= textRecordCount && i < recordOffsets.length; i++) {
    var start = recordOffsets[i];
    var end = (i + 1 < recordOffsets.length) ? recordOffsets[i + 1] : buf.byteLength;
    var recData = new Uint8Array(buf, start, end - start);

    if (compression === 2) {
      var decompressed = decompressPalmDOC(recData);
      for (var b = 0; b < decompressed.length; b++) allBytes.push(decompressed[b]);
    } else {
      for (var b = 0; b < recData.length; b++) allBytes.push(recData[b]);
    }
  }

  var decoder = new TextDecoder('utf-8', { fatal: false });
  var html = decoder.decode(new Uint8Array(allBytes));

  // Split into chapters by <mbp:pagebreak/>
  var chapters = html.split(/<mbp:pagebreak\\s*\\/?>/i).filter(function(ch) {
    return ch.trim().length > 0;
  });

  if (chapters.length === 0) {
    chapters = [html];
  }

  return chapters;
}

var chapters = [];
var currentChapter = 0;

function showChapter(index) {
  if (index < 0 || index >= chapters.length) return;
  currentChapter = index;
  // Sanitize: render via DOM parser to strip scripts
  var parser = new DOMParser();
  var doc = parser.parseFromString(chapters[index], 'text/html');
  // Remove any script tags from parsed content
  doc.querySelectorAll('script').forEach(function(s) { s.remove(); });
  document.getElementById('content').innerHTML = doc.body.innerHTML;
  document.getElementById('content').style.display = 'block';
  document.getElementById('status').style.display = 'none';
  window.scrollTo(0, 0);
  window.ReactNativeWebView.postMessage(JSON.stringify({
    type: 'chapter',
    current: currentChapter,
    total: chapters.length
  }));
}

function loadBook(base64) {
  try {
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    chapters = parseMobi(bytes.buffer);
    window.ReactNativeWebView.postMessage(JSON.stringify({
      type: 'loaded',
      total: chapters.length
    }));
  } catch (e) {
    document.getElementById('status').className = 'error';
    document.getElementById('status').textContent = 'Failed to parse MOBI: ' + e.message;
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
  if (msg.type === 'goto') showChapter(msg.chapter);
});
window.addEventListener('message', function(e) {
  var msg = JSON.parse(e.data);
  if (msg.type === 'load') loadBook(msg.data);
  if (msg.type === 'goto') showChapter(msg.chapter);
});
</script>
</body>
</html>`

export default function MobiReaderScreen() {
  const { id } = useLocalSearchParams<{ id: string }>()
  const router = useRouter()

  const [book, setBook] = useState<Book | null>(null)
  const [loading, setLoading] = useState(true)
  const [chapterCount, setChapterCount] = useState(0)
  const [currentChapter, setCurrentChapter] = useState(0)
  const [toolbarVisible, setToolbarVisible] = useState(false)
  const [bookLoaded, setBookLoaded] = useState(false)

  const webViewRef = useRef<WebView>(null)
  const currentChapterRef = useRef(0)
  const toolbarTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Load book from DB
  useEffect(() => {
    if (id) {
      setLoading(true)
      getBookForReading(id)
        .then((loaded) => {
          if (loaded) {
            setBook(loaded)
            const startChapter = loaded.currentPage || 0
            setCurrentChapter(startChapter)
            currentChapterRef.current = startChapter
          }
        })
        .catch((err) => console.error('Failed to load book for reading:', err))
        .finally(() => setLoading(false))
    }
  }, [id])

  // Send file data to WebView once loaded
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
          updateBookPage(book.id, currentChapterRef.current)
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
        setChapterCount(msg.total)
        // Navigate to saved chapter
        webViewRef.current?.postMessage(
          JSON.stringify({ type: 'goto', chapter: currentChapterRef.current })
        )
      } else if (msg.type === 'chapter') {
        setCurrentChapter(msg.current)
        currentChapterRef.current = msg.current
        if (book?.id) {
          updateBookPage(book.id, msg.current)
        }
      }
    },
    [book?.id]
  )

  const handleBack = useCallback(() => {
    if (book?.id) {
      updateBookPage(book.id, currentChapterRef.current)
    }
    router.back()
  }, [book?.id, router])

  const handlePrevChapter = useCallback(() => {
    if (currentChapterRef.current > 0) {
      const next = currentChapterRef.current - 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', chapter: next })
      )
    }
  }, [])

  const handleNextChapter = useCallback(() => {
    if (currentChapterRef.current < chapterCount - 1) {
      const next = currentChapterRef.current + 1
      webViewRef.current?.postMessage(
        JSON.stringify({ type: 'goto', chapter: next })
      )
    }
  }, [chapterCount])

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: '#fafaf8', justifyContent: 'center', alignItems: 'center' }}>
        <ActivityIndicator size="large" />
        <Text style={{ marginTop: 12, color: '#666' }}>Loading book...</Text>
      </View>
    )
  }

  if (!book || !book.filePath) {
    return (
      <View style={{ flex: 1, backgroundColor: '#fafaf8', justifyContent: 'center', alignItems: 'center' }}>
        <Text style={{ color: '#666', fontSize: 16 }}>Book file not available</Text>
      </View>
    )
  }

  return (
    <View style={{ flex: 1, backgroundColor: '#fafaf8' }}>
      <WebView
        ref={webViewRef}
        source={{ html: MOBI_PARSER_HTML }}
        originWhitelist={['*']}
        onMessage={handleMessage}
        onLoadEnd={() => setBookLoaded(true)}
        style={{ flex: 1 }}
        javaScriptEnabled={true}
        onShouldStartLoadWithRequest={() => true}
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
            backgroundColor: 'rgba(0,0,0,0.7)',
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
              {chapterCount > 0
                ? `Ch ${currentChapter + 1} / ${chapterCount}`
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
            backgroundColor: 'rgba(0,0,0,0.7)',
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
              onPress={handlePrevChapter}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: currentChapter <= 0 ? 0.3 : 1,
              }}
              disabled={currentChapter <= 0}
            >
              <IconSymbol name="chevron.left" size={28} color="#fff" />
            </TouchableOpacity>

            <Text style={{ color: '#fff', fontSize: 16, fontWeight: '500' }}>
              {chapterCount > 0
                ? `${currentChapter + 1} / ${chapterCount}`
                : '...'}
            </Text>

            <TouchableOpacity
              onPress={handleNextChapter}
              style={{
                width: 44,
                height: 44,
                justifyContent: 'center',
                alignItems: 'center',
                opacity: currentChapter >= chapterCount - 1 ? 0.3 : 1,
              }}
              disabled={currentChapter >= chapterCount - 1}
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
