/**
 * Mobile page-capture (G20). Wraps `react-native-view-shot` to produce
 * a base64 data URL of whatever React Native view is currently anchored
 * as the "page" — the reader screen registers its root ref at mount.
 *
 * Why a registry instead of a prop:
 *   - The voice-chat service is constructed at app boot, long before
 *     any reader screen mounts.
 *   - Multiple reader formats (EPUB, PDF, MOBI, DJVU, AZW3) each render
 *     into different React Native trees. Each can register its current
 *     root ref and the capture tool picks whichever is mounted.
 *   - WebView-based readers (EPUB, MOBI, DJVU) include the inline web
 *     content in the screenshot because react-native-view-shot captures
 *     the entire native view subtree, including embedded WebViews.
 *
 * If no ref is registered (e.g. user is on the library screen when the
 * realtime agent asks to inspect the page), `captureCurrentPage()`
 * returns a small placeholder telling the agent the visual isn't
 * available. The agent's instructions already handle this gracefully.
 */
import type { RefObject } from 'react'
import { captureRef } from 'react-native-view-shot'
import type { CaptureResult } from '@rishi/shared/voice-chat'

/**
 * The captured RN component ref. We accept anything `captureRef`
 * accepts: a numeric tag, a ref object, or a host component instance.
 */
type Captureable = number | RefObject<unknown> | { current: unknown } | unknown

let activeRef: Captureable | null = null

/**
 * Reader screens call this on mount and pass `null` on unmount.
 * Idempotent — re-registering with the same ref is a no-op.
 */
export function setActivePageCaptureRef(ref: Captureable | null): void {
  activeRef = ref
}

/** Inspect the current registration. Mostly for tests + debugging. */
export function getActivePageCaptureRef(): Captureable | null {
  return activeRef
}

export interface CaptureOptions {
  detail?: 'low' | 'high'
}

/**
 * Capture the registered ref to a base64 PNG/JPEG and return a
 * `data:` URL the realtime agent can attach to a conversation item.
 *
 * The `detail` parameter mirrors the OpenAI vision input enum — `'low'`
 * caps the longest edge to ~512px (cheaper inputs); `'high'` keeps the
 * native screen resolution.
 */
export async function captureCurrentPage(
  opts: CaptureOptions = {}
): Promise<CaptureResult> {
  const ref = activeRef
  if (ref == null) {
    // No reader is mounted. Surface a tiny placeholder image — the agent
    // text in `renderVisualSection` already preserves graceful behaviour
    // when the tool reports unavailability.
    const placeholder = TINY_TRANSPARENT_PNG_DATA_URL
    return {
      dataUrl: placeholder,
      width: 1,
      height: 1,
      bytes: estimateDataUrlBytes(placeholder)
    }
  }

  const detail = opts.detail ?? 'low'
  const result = await captureRef(ref as never, {
    result: 'data-uri',
    format: detail === 'high' ? 'png' : 'jpg',
    quality: detail === 'high' ? 1 : 0.6,
    // react-native-view-shot can downscale at capture time via `width`.
    // 512 mirrors OpenAI's low-detail short-edge tier.
    ...(detail === 'low' ? { width: 512 } : {})
  })

  // captureRef's data URI is `data:image/<fmt>;base64,<payload>`.
  const dimensions = inferDimensionsFromDataUrl(result)
  return {
    dataUrl: result,
    width: dimensions.width,
    height: dimensions.height,
    bytes: estimateDataUrlBytes(result)
  }
}

const TINY_TRANSPARENT_PNG_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='

function estimateDataUrlBytes(dataUrl: string): number {
  const commaIndex = dataUrl.indexOf(',')
  if (commaIndex === -1) return dataUrl.length
  const payload = dataUrl.slice(commaIndex + 1)
  // base64 → bytes ≈ payload.length * 3/4.
  return Math.floor((payload.length * 3) / 4)
}

/**
 * react-native-view-shot does not return dimensions — we'd have to
 * decode the image. For now, return placeholder dimensions; the
 * realtime SDK doesn't use width/height for routing, only for logging.
 * Reader screens that need pixel-perfect dimensions can call
 * `captureRef(..., { result: 'tmpfile' })` and read the file metadata.
 */
function inferDimensionsFromDataUrl(_dataUrl: string): { width: number; height: number } {
  return { width: 0, height: 0 }
}
