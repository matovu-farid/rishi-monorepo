/**
 * Register a reader screen's "active page" ref with the page-capture
 * registry so the voice-chat vision tool can screenshot it.
 *
 * G20 — without a registered ref, `captureCurrentPage()` returns a 1×1
 * placeholder and the realtime agent never sees the page contents.
 * Each reader screen (EPUB, PDF, MOBI, AZW3, DJVU) calls this hook with
 * a ref attached to the visible page area (the WebView, the epubjs
 * Reader view, etc — not the toolbar).
 *
 * The registry is a single-slot ring: a fresh mount overwrites whatever
 * was there. On unmount we clear the slot only if we still own it, so
 * out-of-order unmounts during a screen transition don't accidentally
 * wipe the newly-mounted screen's ref.
 */
import { useEffect } from 'react'
import type { RefObject } from 'react'
import {
  getActivePageCaptureRef,
  setActivePageCaptureRef,
} from '@/lib/voice-chat/page-capture'

type AnyRef = RefObject<unknown> | { current: unknown }

export function usePageCaptureRef(ref: AnyRef | null | undefined): void {
  useEffect(() => {
    if (!ref) return
    setActivePageCaptureRef(ref)
    return () => {
      // Only clear if we still own the slot — if another screen has
      // since registered, we shouldn't nuke its registration.
      if (getActivePageCaptureRef() === ref) {
        setActivePageCaptureRef(null)
      }
    }
  }, [ref])
}
