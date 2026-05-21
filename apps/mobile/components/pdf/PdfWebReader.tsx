/**
 * PdfWebReader — React Native PDF reader implemented as a pdfjs viewer
 * inside a WebView. Provides text selection, highlights, outline (TOC),
 * go-to-page, and TTS-friendly per-page text extraction.
 *
 * Design rationale (Batch 5):
 *   The previous mobile reader used `react-native-pdf` which doesn't
 *   expose text selection / per-character rects to JS. Highlights,
 *   read-aloud-from-selection, and TOC are all selection- or
 *   pdfjs-dependent features. Rather than building a separate
 *   selection-only WebView alongside react-native-pdf, this component
 *   pivots to a single WebView that hosts pdfjs and handles rendering
 *   too — unblocking G06/G07/G08/G09/G17 in one piece of infrastructure.
 *
 *   The fallback (keep react-native-pdf for rendering + hidden WebView
 *   for selection) is documented in `.parity/BATCH-5-NOTES.md`. Adopt
 *   it only if pdfjs render perf in WebView turns out unacceptable for
 *   large books.
 */

import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react'
import { View, ActivityIndicator, Text, type ViewStyle } from 'react-native'
import { WebView, type WebViewMessageEvent } from 'react-native-webview'
import { File as ExpoFile } from 'expo-file-system'

import { PDF_READER_HTML } from './webview-template'
import {
  parseOutgoing,
  serializeIncoming,
  type PdfOutlineItem,
  type PdfWebViewIncomingMessage,
  type PdfWebViewOutgoingMessage,
} from './pdf-webview-bridge'
import type { PdfLocator } from '@rishi/shared/types/pdf-locator'

export interface PdfWebReaderHandle {
  /** Scroll to a 1-based page number, optionally with a sub-page pixel offset. */
  goToPage(page: number, offset?: number): void
  /** Draw a highlight overlay. */
  addHighlight(id: string, color: string, locator: PdfLocator): void
  /** Remove a highlight overlay. */
  removeHighlight(id: string): void
  /** Replace all overlays in one shot (initial load). */
  setHighlights(list: Array<{ id: string; color: string; locator: PdfLocator }>): void
  /** Convert the current selection into a new highlight (with the given id). */
  highlightSelection(id: string, color: string): void
  /** Clear any active selection. */
  clearSelection(): void
  /**
   * Request paragraphs for a page. Returns a promise that resolves when the
   * WebView responds with the matching `requestId`. Times out after 5s.
   */
  getPageText(pageNumber: number): Promise<Array<{ index: string; text: string }>>
}

export interface PdfWebReaderProps {
  /** Absolute filesystem URI of the local PDF file (file:// or content://). */
  fileUri: string
  /** Fires once pdfjs has parsed the document. */
  onLoad?(info: { numPages: number; outline: PdfOutlineItem[] }): void
  /** Fires on scroll-driven page changes. */
  onPageChange?(pageNumber: number, offset: number): void
  /** Fires when the user finishes a text selection. */
  onSelection?(sel: {
    pageNumber: number
    text: string
    locator: PdfLocator
    anchor: { x: number; y: number }
  }): void
  onSelectionCleared?(): void
  /** Fires when the user taps an existing highlight. */
  onHighlightTapped?(highlightId: string, anchor: { x: number; y: number }): void
  onError?(message: string): void
  style?: ViewStyle
}

// Pending getPageText requests, keyed by requestId.
interface PageTextWaiter {
  resolve: (rows: Array<{ index: string; text: string }>) => void
  reject: (err: Error) => void
  timer: ReturnType<typeof setTimeout>
}

export const PdfWebReader = forwardRef<PdfWebReaderHandle, PdfWebReaderProps>(
  function PdfWebReader(props, ref): React.ReactElement {
    const webViewRef = useRef<WebView>(null)
    const [ready, setReady] = useState(false)
    const [loaded, setLoaded] = useState(false)
    const [loadError, setLoadError] = useState<string | null>(null)
    const pageTextWaitersRef = useRef<Map<string, PageTextWaiter>>(new Map())
    const pendingFileLoadRef = useRef<string | null>(props.fileUri)

    const propsRef = useRef(props)
    propsRef.current = props

    // ---- Send ----
    const sendToWebView = useCallback((msg: PdfWebViewIncomingMessage): void => {
      const json = serializeIncoming(msg)
      // injectJavaScript is sync from RN's side, fire-and-forget.
      const escaped = json.replace(/\\/g, '\\\\').replace(/'/g, "\\'")
      webViewRef.current?.injectJavaScript(
        `(function(){var e={data:'${escaped}'};` +
          `window.dispatchEvent(new MessageEvent('message',e));})(); true;`
      )
    }, [])

    // ---- Load file once ready ----
    useEffect(() => {
      if (!ready) return
      const uri = pendingFileLoadRef.current
      if (!uri) return
      // Read PDF bytes as base64 and ship into the WebView.
      void (async () => {
        try {
          const file = new ExpoFile(uri)
          const base64 = await file.base64()
          sendToWebView({ type: 'load', data: base64 })
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e)
          setLoadError(`Failed to read PDF: ${msg}`)
          propsRef.current.onError?.(msg)
        }
      })()
    }, [ready, sendToWebView])

    // ---- Receive ----
    const handleMessage = useCallback((event: WebViewMessageEvent): void => {
      const parsed = parseOutgoing(event.nativeEvent.data)
      if (!parsed) return
      dispatchOutgoing(parsed)
    }, [])

    const dispatchOutgoing = (msg: PdfWebViewOutgoingMessage): void => {
      switch (msg.type) {
        case 'ready':
          setReady(true)
          break
        case 'loaded':
          setLoaded(true)
          propsRef.current.onLoad?.({ numPages: msg.numPages, outline: msg.outline })
          break
        case 'pageChanged':
          propsRef.current.onPageChange?.(msg.pageNumber, msg.offset)
          break
        case 'selection':
          propsRef.current.onSelection?.({
            pageNumber: msg.pageNumber,
            text: msg.text,
            locator: msg.locator,
            anchor: msg.anchor,
          })
          break
        case 'selectionCleared':
          propsRef.current.onSelectionCleared?.()
          break
        case 'pageText': {
          const waiter = pageTextWaitersRef.current.get(msg.requestId)
          if (!waiter) return
          clearTimeout(waiter.timer)
          pageTextWaitersRef.current.delete(msg.requestId)
          waiter.resolve(msg.paragraphs)
          break
        }
        case 'highlightTapped':
          propsRef.current.onHighlightTapped?.(msg.highlightId, msg.anchor)
          break
        case 'error':
          propsRef.current.onError?.(msg.message)
          break
      }
    }

    // ---- Imperative handle ----
    useImperativeHandle(
      ref,
      (): PdfWebReaderHandle => ({
        goToPage(page: number, offset?: number): void {
          sendToWebView({ type: 'goToPage', page, offset })
        },
        addHighlight(id, color, locator) {
          sendToWebView({ type: 'addHighlight', id, color, locator })
        },
        removeHighlight(id) {
          sendToWebView({ type: 'removeHighlight', id })
        },
        setHighlights(list) {
          sendToWebView({ type: 'setHighlights', highlights: list })
        },
        highlightSelection(id, color) {
          sendToWebView({ type: 'highlightSelection', id, color })
        },
        clearSelection() {
          sendToWebView({ type: 'clearSelection' })
        },
        getPageText(pageNumber) {
          return new Promise((resolve, reject) => {
            const requestId = `pt-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
            const timer = setTimeout(() => {
              if (pageTextWaitersRef.current.delete(requestId)) {
                reject(new Error(`getPageText(${pageNumber}) timed out`))
              }
            }, 5000)
            pageTextWaitersRef.current.set(requestId, { resolve, reject, timer })
            sendToWebView({ type: 'getPageText', requestId, pageNumber })
          })
        },
      }),
      [sendToWebView]
    )

    return (
      <View style={[{ flex: 1, backgroundColor: '#1a1a1a' }, props.style]}>
        <WebView
          ref={webViewRef}
          originWhitelist={['*']}
          source={{ html: PDF_READER_HTML }}
          onMessage={handleMessage}
          onError={(e) => {
            const msg = e.nativeEvent.description || 'WebView error'
            setLoadError(msg)
            propsRef.current.onError?.(msg)
          }}
          javaScriptEnabled
          domStorageEnabled
          allowFileAccess
          allowFileAccessFromFileURLs
          allowUniversalAccessFromFileURLs
          mixedContentMode="always"
          testID="pdf-webview"
          style={{ flex: 1, backgroundColor: '#1a1a1a' }}
        />
        {!loaded && !loadError ? (
          <View
            pointerEvents="none"
            style={{
              position: 'absolute',
              inset: 0,
              justifyContent: 'center',
              alignItems: 'center',
            }}
          >
            <ActivityIndicator size="large" color="#fff" />
            <Text style={{ color: '#ccc', marginTop: 8 }}>Opening PDF…</Text>
          </View>
        ) : null}
        {loadError ? (
          <View
            style={{
              position: 'absolute',
              inset: 0,
              justifyContent: 'center',
              alignItems: 'center',
              backgroundColor: 'rgba(0,0,0,0.85)',
            }}
          >
            <Text style={{ color: '#fff', textAlign: 'center', paddingHorizontal: 24 }}>
              {loadError}
            </Text>
          </View>
        ) : null}
      </View>
    )
  }
)
