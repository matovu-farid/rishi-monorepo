import EventEmitter from "eventemitter3";
import { TTSQueueEvents } from "./ipc_handles";
import { getAuthToken } from "./auth";
import { ttsCache } from "./ttsCache";

const AUDIO_WORKER_URL = "https://rishi-worker.faridmato90.workers.dev/api/audio/speech";
const MAX_RETRIES = 3;
const RETRY_DELAY = 1000;
const REQUEST_TIMEOUT = 60000;
const MAX_QUEUE_SIZE = 15;
const BATCH_SIZE = 8;

interface TTSRequest {
  bookId: string;
  cfiRange: string;
  text: string;
  priority: number;
  retries: number;
}

class TTSQueue extends EventEmitter {
  private queue: TTSRequest[] = [];
  private processing = false;
  private activeRequests = new Map<string, Promise<string>>();

  private key(bookId: string, cfiRange: string): string {
    return `${bookId}-${cfiRange}`;
  }

  async requestAudio(bookId: string, cfiRange: string, text: string, priority = 0): Promise<string> {
    const k = this.key(bookId, cfiRange);
    const existing = this.activeRequests.get(k);
    if (existing) return existing;

    const promise = this._enqueue({ bookId, cfiRange, text, priority, retries: 0 });
    this.activeRequests.set(k, promise);
    promise.finally(() => this.activeRequests.delete(k));
    return promise;
  }

  private async _enqueue(req: TTSRequest): Promise<string> {
    // Check disk cache before enqueueing a network request
    try {
      const cachedUrl = await ttsCache.getCachedAudioUrl(
        req.bookId,
        req.cfiRange,
        req.text,
      );
      if (cachedUrl) {
        return cachedUrl;
      }
    } catch {
      // Cache lookup failed -- fall through to network request
    }

    if (this.queue.length >= MAX_QUEUE_SIZE) {
      // Drop lowest priority item
      this.queue.sort((a, b) => b.priority - a.priority);
      this.queue.pop();
    }

    return new Promise<string>((resolve, reject) => {
      const k = this.key(req.bookId, req.cfiRange);

      const onReady = (data: { key: string; url: string }) => {
        if (data.key === k) {
          cleanup();
          resolve(data.url);
        }
      };
      const onError = (data: { key: string; error: string }) => {
        if (data.key === k) {
          cleanup();
          reject(new Error(data.error));
        }
      };
      const cleanup = () => {
        this.off(TTSQueueEvents.AUDIO_READY, onReady);
        this.off(TTSQueueEvents.AUDIO_ERROR, onError);
      };

      this.on(TTSQueueEvents.AUDIO_READY, onReady);
      this.on(TTSQueueEvents.AUDIO_ERROR, onError);

      this.queue.push(req);
      this.queue.sort((a, b) => b.priority - a.priority);
      if (!this.processing) this.processQueue();
    });
  }

  private async processQueue(): Promise<void> {
    if (this.processing || this.queue.length === 0) return;
    this.processing = true;

    while (this.queue.length > 0) {
      const batch = this.queue.splice(0, BATCH_SIZE);
      await Promise.allSettled(batch.map((req) => this.processRequest(req)));
    }

    this.processing = false;
  }

  private async processRequest(req: TTSRequest): Promise<void> {
    const k = this.key(req.bookId, req.cfiRange);
    try {
      const token = await getAuthToken();
      const devBypass = await window.electron.getDevBypassSecret();

      const headers: Record<string, string> = {
        "Content-Type": "application/json",
      };
      if (token) headers["Authorization"] = `Bearer ${token}`;
      else if (devBypass) headers["X-Dev-Bypass"] = devBypass;

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT);

      const response = await fetch(AUDIO_WORKER_URL, {
        method: "POST",
        headers,
        body: JSON.stringify({
          input: req.text,
          voice: "alloy",
          model: "tts-1",
          response_format: "mp3",
        }),
        signal: controller.signal,
      });

      clearTimeout(timeout);

      if (!response.ok) {
        throw new Error(`TTS API error: ${response.status}`);
      }

      const blob = await response.blob();

      // Save to disk cache (fire-and-forget -- do not block playback)
      ttsCache
        .saveCachedAudio(req.bookId, req.cfiRange, blob, req.text)
        .catch((err) =>
          console.warn("[ttsQueue] failed to save audio to cache:", err),
        );

      const url = URL.createObjectURL(blob);
      this.emit(TTSQueueEvents.AUDIO_READY, { key: k, url });
    } catch (err) {
      if (req.retries < MAX_RETRIES) {
        await new Promise((r) => setTimeout(r, RETRY_DELAY * (req.retries + 1)));
        req.retries++;
        this.queue.unshift(req);
        if (!this.processing) this.processQueue();
      } else {
        this.emit(TTSQueueEvents.AUDIO_ERROR, {
          key: k,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }

  clearQueue(): void {
    this.queue = [];
  }

  getStatus() {
    return {
      pending: this.queue.length,
      isProcessing: this.processing,
      active: this.activeRequests.size,
    };
  }
}

export const ttsQueue = new TTSQueue();
