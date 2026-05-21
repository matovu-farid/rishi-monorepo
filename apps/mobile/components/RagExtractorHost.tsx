/**
 * Mounts hidden WebViews for PDF and DJVU text extraction.
 *
 * Mobile-only entrypoint that bridges the chunker's per-format extractor
 * ports (lib/rag/chunker.ts) to a real WebView that runs pdfjs / djvu.js
 * from CDN. See lib/rag/extractors/* for the HTML templates and contracts.
 *
 * Mount this once at app root (apps/mobile/app/_layout.tsx) — it renders a
 * 0x0 view containing two WebViews. Each WebView lazily executes one
 * extraction job at a time; concurrent calls queue.
 */

import { useEffect, useRef } from 'react'
import { View, type ViewStyle } from 'react-native'
import { WebView, type WebViewMessageEvent } from 'react-native-webview'
import { File as ExpoFile } from 'expo-file-system'

import { setPdfExtractor, setDjvuExtractor, type ExtractedPage } from '@/lib/rag/chunker'
import {
  PDF_EXTRACTOR_HTML,
  setPdfExtractorDriver,
  clearPdfExtractorDriver,
} from '@/lib/rag/extractors/pdf-text-extractor'
import {
  DJVU_EXTRACTOR_HTML,
  setDjvuExtractorDriver,
  clearDjvuExtractorDriver,
} from '@/lib/rag/extractors/djvu-text-extractor'

const HIDDEN_STYLE: ViewStyle = {
  position: 'absolute',
  width: 0,
  height: 0,
  overflow: 'hidden',
  opacity: 0,
}

// ---------------------------------------------------------------------------
// Job queue
// ---------------------------------------------------------------------------

interface ExtractionJob {
  filePath: string
  resolve: (pages: ExtractedPage[]) => void
  reject: (err: Error) => void
}

function makeQueue(): {
  enqueue: (job: ExtractionJob) => void
  takeNext: () => ExtractionJob | undefined
} {
  const jobs: ExtractionJob[] = []
  return {
    enqueue: (job) => {
      jobs.push(job)
    },
    takeNext: () => jobs.shift(),
  }
}

export function RagExtractorHost(): React.ReactElement {
  const pdfWebViewRef = useRef<WebView>(null)
  const djvuWebViewRef = useRef<WebView>(null)

  const pdfQueueRef = useRef(makeQueue())
  const djvuQueueRef = useRef(makeQueue())
  const pdfBusyRef = useRef(false)
  const djvuBusyRef = useRef(false)
  const pdfReadyRef = useRef(false)
  const djvuReadyRef = useRef(false)
  const pdfActiveJobRef = useRef<ExtractionJob | null>(null)
  const djvuActiveJobRef = useRef<ExtractionJob | null>(null)

  // ----- Drive functions registered with the chunker -----

  useEffect(() => {
    const drivePdf = (filePath: string): Promise<ExtractedPage[]> =>
      new Promise<ExtractedPage[]>((resolve, reject) => {
        pdfQueueRef.current.enqueue({ filePath, resolve, reject })
        runNextPdf()
      })

    const driveDjvu = (filePath: string): Promise<ExtractedPage[]> =>
      new Promise<ExtractedPage[]>((resolve, reject) => {
        djvuQueueRef.current.enqueue({ filePath, resolve, reject })
        runNextDjvu()
      })

    setPdfExtractor(drivePdf)
    setDjvuExtractor(driveDjvu)
    setPdfExtractorDriver(drivePdf)
    setDjvuExtractorDriver(driveDjvu)

    return () => {
      clearPdfExtractorDriver()
      clearDjvuExtractorDriver()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // ----- Job runners -----

  const runNextPdf = async (): Promise<void> => {
    if (pdfBusyRef.current || !pdfReadyRef.current) return
    const next = pdfQueueRef.current.takeNext()
    if (!next) return
    pdfBusyRef.current = true
    pdfActiveJobRef.current = next
    try {
      const file = new ExpoFile(next.filePath)
      const base64 = await file.base64()
      pdfWebViewRef.current?.postMessage(JSON.stringify({ type: 'load', data: base64 }))
    } catch (err) {
      pdfActiveJobRef.current = null
      pdfBusyRef.current = false
      next.reject(err instanceof Error ? err : new Error(String(err)))
      runNextPdf()
    }
  }

  const runNextDjvu = async (): Promise<void> => {
    if (djvuBusyRef.current || !djvuReadyRef.current) return
    const next = djvuQueueRef.current.takeNext()
    if (!next) return
    djvuBusyRef.current = true
    djvuActiveJobRef.current = next
    try {
      const file = new ExpoFile(next.filePath)
      const base64 = await file.base64()
      djvuWebViewRef.current?.postMessage(JSON.stringify({ type: 'load', data: base64 }))
    } catch (err) {
      djvuActiveJobRef.current = null
      djvuBusyRef.current = false
      next.reject(err instanceof Error ? err : new Error(String(err)))
      runNextDjvu()
    }
  }

  // ----- Message handlers -----

  const onPdfMessage = (event: WebViewMessageEvent): void => {
    let msg: { type: string; pages?: ExtractedPage[]; message?: string }
    try {
      msg = JSON.parse(event.nativeEvent.data)
    } catch {
      return
    }

    if (msg.type === 'ready') {
      pdfReadyRef.current = true
      runNextPdf()
      return
    }

    const job = pdfActiveJobRef.current
    if (!job) return
    pdfActiveJobRef.current = null
    pdfBusyRef.current = false

    if (msg.type === 'paragraphs' && msg.pages) {
      job.resolve(msg.pages)
    } else if (msg.type === 'error') {
      job.reject(new Error(msg.message ?? 'pdf extraction failed'))
    } else {
      job.reject(new Error(`Unexpected pdf message: ${msg.type}`))
    }
    runNextPdf()
  }

  const onDjvuMessage = (event: WebViewMessageEvent): void => {
    let msg: { type: string; pages?: ExtractedPage[]; message?: string }
    try {
      msg = JSON.parse(event.nativeEvent.data)
    } catch {
      return
    }

    if (msg.type === 'ready') {
      djvuReadyRef.current = true
      runNextDjvu()
      return
    }

    const job = djvuActiveJobRef.current
    if (!job) return
    djvuActiveJobRef.current = null
    djvuBusyRef.current = false

    if (msg.type === 'paragraphs' && msg.pages) {
      job.resolve(msg.pages)
    } else if (msg.type === 'error') {
      job.reject(new Error(msg.message ?? 'djvu extraction failed'))
    } else {
      job.reject(new Error(`Unexpected djvu message: ${msg.type}`))
    }
    runNextDjvu()
  }

  return (
    <View style={HIDDEN_STYLE} pointerEvents="none">
      <WebView
        ref={pdfWebViewRef}
        source={{ html: PDF_EXTRACTOR_HTML }}
        originWhitelist={['*']}
        onMessage={onPdfMessage}
        javaScriptEnabled
        onShouldStartLoadWithRequest={(req) =>
          req.url.startsWith('about:') ||
          req.url.startsWith('data:') ||
          req.url.includes('cdn.jsdelivr.net')
        }
      />
      <WebView
        ref={djvuWebViewRef}
        source={{ html: DJVU_EXTRACTOR_HTML }}
        originWhitelist={['*']}
        onMessage={onDjvuMessage}
        javaScriptEnabled
        onShouldStartLoadWithRequest={(req) =>
          req.url.startsWith('about:') ||
          req.url.startsWith('data:') ||
          req.url.includes('cdn.jsdelivr.net')
        }
      />
    </View>
  )
}
