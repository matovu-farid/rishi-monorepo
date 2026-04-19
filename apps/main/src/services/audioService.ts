// apps/main/src/services/audioService.ts
import {
  getTTSAudioPath,
  requestTTSAudio,
} from "@/modules/ipc_handel_functions";
import type { ParagraphWithIndex } from "@/models/player_control";

export class AudioService {
  public audioElement: HTMLAudioElement;
  private audioCache: Map<string, string> = new Map();
  private priority: number = 3;
  private _prefetchTimer: ReturnType<typeof setTimeout> | null = null;
  private _prefetchGeneration: number = 0;

  // Callbacks — wired to machine.send by usePlayerMachine
  public onAudioEnded: () => void = () => {};
  public onAudioError: (error: MediaError | null) => void = () => {};

  constructor(audioElement: HTMLAudioElement) {
    this.audioElement = audioElement;
  }

  // --- Playback ---

  async loadAndPlay(audioPath: string): Promise<void> {
    this.audioElement.pause();
    this.audioElement.currentTime = 0;
    this.audioElement.src = audioPath;
    this.audioElement.load();

    await new Promise<void>((resolve, reject) => {
      const handleCanPlay = () => {
        this.audioElement.removeEventListener("canplaythrough", handleCanPlay);
        this.audioElement.removeEventListener("error", handleError);
        resolve();
      };
      const handleError = (e: Event) => {
        this.audioElement.removeEventListener("canplaythrough", handleCanPlay);
        this.audioElement.removeEventListener("error", handleError);
        const mediaError = (e.target as HTMLAudioElement)?.error;
        reject(new Error(mediaError?.message || `Audio load error (code ${mediaError?.code ?? "unknown"})`));
      };
      this.audioElement.addEventListener("canplaythrough", handleCanPlay, {
        once: true,
      });
      this.audioElement.addEventListener("error", handleError, { once: true });
    });

    // Wire persistent listeners (removed+re-added each play to avoid accumulation)
    this.audioElement.removeEventListener("ended", this._handleEnded);
    this.audioElement.removeEventListener("error", this._handleError);
    this.audioElement.addEventListener("ended", this._handleEnded);
    this.audioElement.addEventListener("error", this._handleError);

    await this.audioElement.play();
  }

  pauseAudio(): void {
    this.audioElement.pause();
  }

  async resumeAudio(): Promise<void> {
    await this.audioElement.play();
  }

  stopAudio(): void {
    this.audioElement.pause();
    this.audioElement.currentTime = 0;
    this.audioElement.removeEventListener("ended", this._handleEnded);
    this.audioElement.removeEventListener("error", this._handleError);
  }

  // --- TTS Fetching ---

  async fetchAudio(
    bookId: string,
    paragraph: ParagraphWithIndex,
    skipCache = false
  ): Promise<string> {
    if (!paragraph.text.trim()) {
      throw new Error("Empty paragraph text");
    }

    if (!skipCache) {
      // In-memory cache
      const cached = this.audioCache.get(paragraph.index);
      if (cached) return cached;

      // Disk cache
      try {
        const diskCached = await getTTSAudioPath(bookId, paragraph.index);
        if (diskCached) {
          this.addToCache(paragraph.index, diskCached);
          return diskCached;
        }
      } catch {
        // Disk cache miss — fall through to request
      }
    }

    const audioPath = await requestTTSAudio(
      bookId,
      paragraph.index,
      paragraph.text,
      this.getNextPriority()
    );
    this.addToCache(paragraph.index, audioPath);
    return audioPath;
  }

  // --- Cache ---

  addToCache(key: string, path: string): void {
    this.audioCache.set(key, path);
  }

  getCachedPath(key: string): string | undefined {
    return this.audioCache.get(key);
  }

  clearCache(): void {
    this.audioCache.clear();
  }

  deleteCacheEntry(key: string): void {
    this.audioCache.delete(key);
  }

  // --- Prefetch ---

  schedulePrefetch(
    currentIndex: number,
    currentParagraphs: ParagraphWithIndex[],
    nextPageParagraphs: ParagraphWithIndex[],
    prevPageParagraphs: ParagraphWithIndex[],
    bookId: string,
    immediate: boolean
  ): void {
    if (this._prefetchTimer) clearTimeout(this._prefetchTimer);
    const generation = ++this._prefetchGeneration;
    const delay = immediate ? 0 : 200;

    this._prefetchTimer = setTimeout(() => {
      if (generation !== this._prefetchGeneration) return;

      // Prefetch nearby paragraphs on current page
      for (let i = 1; i <= 3; i++) {
        const idx = currentIndex + i;
        if (idx < currentParagraphs.length) {
          void this.fetchAudio(bookId, currentParagraphs[idx]).catch(() => {});
        }
      }
      for (let i = 1; i <= 3; i++) {
        const idx = currentIndex - i;
        if (idx >= 0) {
          void this.fetchAudio(bookId, currentParagraphs[idx]).catch(() => {});
        }
      }

      // Prefetch across page boundaries
      if (currentIndex === 0) {
        for (let i = 0; i < Math.min(3, prevPageParagraphs.length); i++) {
          void this.fetchAudio(bookId, prevPageParagraphs[i]).catch(() => {});
        }
      }
      if (currentIndex >= currentParagraphs.length - 1) {
        for (let i = 0; i < Math.min(3, nextPageParagraphs.length); i++) {
          void this.fetchAudio(bookId, nextPageParagraphs[i]).catch(() => {});
        }
      }
    }, delay);
  }

  cancelPrefetch(): void {
    if (this._prefetchTimer) {
      clearTimeout(this._prefetchTimer);
      this._prefetchTimer = null;
    }
    this._prefetchGeneration++;
  }

  // --- Cleanup ---

  cleanup(): void {
    this.cancelPrefetch();
    this.audioElement.removeEventListener("ended", this._handleEnded);
    this.audioElement.removeEventListener("error", this._handleError);
    this.audioElement.pause();
    this.audioElement.src = "";
    this.audioCache.clear();
  }

  // --- Private ---

  private _handleEnded = (): void => {
    this.onAudioEnded();
  };

  private _handleError = (): void => {
    this.onAudioError(this.audioElement.error);
  };

  private getNextPriority(): number {
    return ++this.priority;
  }
}
