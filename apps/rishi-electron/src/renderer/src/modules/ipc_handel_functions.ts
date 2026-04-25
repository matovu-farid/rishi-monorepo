/**
 * TTS service wrapper functions for Electron.
 * Replaces Tauri's convertFileSrc with blob URL handling since
 * Electron TTS returns blob URLs directly from the renderer-side queue.
 */
import { ttsService } from "./ttsService";
import { captureError } from "../utils/sentry";

export const getTTSAudioPath = async (bookId: string, cfiRange: string) => {
  try {
    return await ttsService.getAudioPath(bookId, cfiRange);
  } catch (error) {
    console.error("Failed to get audio path:", error);
    return null;
  }
};

export const getTtsQueueStatus = () => {
  try {
    return ttsService.getQueueStatus();
  } catch (error) {
    console.error("Failed to get queue status:", error);
    return { pending: 0, isProcessing: false, active: 0 };
  }
};

export const ttsClearBookCache = async (bookId: string) => {
  try {
    await ttsService.clearBookCache(bookId);
  } catch (error) {
    console.error("Failed to clear book cache:", error);
    throw error;
  }
};
export const ttsGetBookCacheSize = async (bookId: string) => {
  try {
    return await ttsService.getBookCacheSize(bookId);
  } catch (error) {
    console.error("Failed to get book cache size:", error);
    return 0;
  }
};

export const requestTTSAudio = async (
  bookId: string,
  cfiRange: string,
  text: string,
  priority = 0
) => {
  try {
    // In Electron, ttsService.requestAudio already returns a blob URL
    const audioUrl = await ttsService.requestAudio(
      bookId,
      cfiRange,
      text,
      priority
    );
    return audioUrl;
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    console.error(`TTS request failed [${bookId}]: ${msg}`);
    captureError(error, {
      operation: "tts-request",
      step: "requestTTSAudio",
      bookId,
      cfiRange,
      textLength: text.length,
      priority,
    });
    throw error;
  }
};
