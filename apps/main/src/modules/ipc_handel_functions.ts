import { convertFileSrc } from "@tauri-apps/api/core";
import { ttsService } from "./ttsService";

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
    const audioFile = await ttsService.requestAudio(
      bookId,
      cfiRange,
      text,
      priority
    );
    return convertFileSrc(audioFile);
  } catch (error) {
    console.error("TTS request failed:", error);
    throw error;
  }
};
