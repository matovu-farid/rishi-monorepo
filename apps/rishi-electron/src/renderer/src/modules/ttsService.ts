import EventEmitter from "eventemitter3";
import { ttsQueue } from "./ttsQueue";
import { ttsCache } from "./ttsCache";

class TTSService extends EventEmitter {
  private activeRequests = new Map<string, Promise<string>>();

  private key(bookId: string, cfiRange: string): string {
    return `${bookId}-${cfiRange}`;
  }

  async requestAudio(bookId: string, cfiRange: string, text: string, priority = 0): Promise<string> {
    const k = this.key(bookId, cfiRange);
    const existing = this.activeRequests.get(k);
    if (existing) return existing;

    const promise = ttsQueue.requestAudio(bookId, cfiRange, text, priority);
    this.activeRequests.set(k, promise);
    promise.finally(() => this.activeRequests.delete(k));
    return promise;
  }

  async getAudioPath(bookId: string, cfiRange: string): Promise<string | null> {
    const k = this.key(bookId, cfiRange);
    return this.activeRequests.get(k) ?? null;
  }

  cancelRequest(bookId: string, cfiRange: string): void {
    this.activeRequests.delete(this.key(bookId, cfiRange));
  }

  clearQueue(): void {
    ttsQueue.clearQueue();
  }

  getQueueStatus() {
    return ttsQueue.getStatus();
  }

  async clearBookCache(bookId: string): Promise<void> {
    await ttsCache.clearBookCache(bookId);
  }

  async getBookCacheSize(_bookId: string): Promise<number> {
    return ttsCache.getTotalCacheSize();
  }
}

export const ttsService = new TTSService();
