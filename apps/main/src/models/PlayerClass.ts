import EventEmitter from "eventemitter3";
// @ts-ignore
import {
  getTTSAudioPath,
  requestTTSAudio,
} from "@/modules/ipc_handel_functions";
import { ParagraphWithIndex } from "./player_control";
import { eventBus, EventBusEvent } from "@/utils/bus";
import { PlayingState } from "@/utils/bus";
import isEqual from "fast-deep-equal";
import { logStateEvent } from "@/utils/stateDump";

export enum Direction {
  Forward = "forward",
  Backward = "backward",
}
export enum PlayerEvent {
  PARAGRAPH_INDEX_CHANGED = "paragraphIndexChanged",
  PLAYING_STATE_CHANGED = "playingStateChanged",
  ERRORS_CHANGED = "errorsChanged",
}
export type PlayerEventMap = {
  [PlayerEvent.PARAGRAPH_INDEX_CHANGED]: [ParagraphIndexChangedEvent];
  [PlayerEvent.PLAYING_STATE_CHANGED]: [PlayingState];
  [PlayerEvent.ERRORS_CHANGED]: [ErrorsChangedEvent];
};

export interface ParagraphIndexChangedEvent {
  index: number;
  paragraph: ParagraphWithIndex | null;
}
export type PlayingStateChangedEvent = [PlayingState];

export interface ErrorsChangedEvent {
  errors: string[];
}

export class Player extends EventEmitter<PlayerEventMap> {
  private currentViewParagraphs: ParagraphWithIndex[] = [];
  private nextPageParagraphs: ParagraphWithIndex[] = [];
  private previousPageParagraphs: ParagraphWithIndex[] = [];
  private playingState: PlayingState = PlayingState.Stopped;
  private currentParagraphIndex: number = 0;
  private bookId: string = "";
  private audioCache: Map<string, string> = new Map();
  private priority: number = 3;
  private errors: string[] = [];
  public audioElement: HTMLAudioElement;
  private direction: Direction = Direction.Forward;
  private eventBusSubscriptions: Array<{ event: string; handler: (...args: any[]) => void }> = [];
  private _aborted: boolean = false;
  private _prefetchGeneration: number = 0;
  private _prefetchTimer: ReturnType<typeof setTimeout> | null = null;
  private _autoAdvancing: boolean = false;
  private _waitingTimeout: ReturnType<typeof setTimeout> | null = null;
  private _stoppedByTimeout: boolean = false;

  constructor(audioElement: HTMLAudioElement) {
    super();
    this.audioElement = audioElement;
  }

  async initialize(bookId: string): Promise<void> {
    this._aborted = false;
    this._stoppedByTimeout = false;
    this.setPlayingState(PlayingState.Stopped);
    void this.setParagraphIndex(0);

    this.bookId = bookId;

    this.errors = [];
    // Clear audio cache from previous book to prevent cross-book cache collisions
    // (MOBI/DJVU use non-book-specific index keys like mobi-0-0)
    this.audioCache.clear();

    // Clear any previous subscriptions to prevent leaks on re-initialize
    this.removeEventBusSubscriptions();

    const onNewParagraphs = async (paragraphs: ParagraphWithIndex[]) => {
      if (paragraphs.length === 0) return;
      if (this._aborted) return;
      // Also resume if the _waitingTimeout fired and transitioned to Stopped
      // before paragraphs arrived (slow IPC fetch). Don't resume from a
      // user-initiated stop — only from timeout-induced stops.
      const wasWaiting =
        this.playingState === PlayingState.WaitingForNewParagraphs ||
        (this.playingState === PlayingState.Stopped && this._stoppedByTimeout);
      if (isEqual(this.currentViewParagraphs, paragraphs)) return;
      this.currentViewParagraphs = paragraphs;
      if (wasWaiting) {
        // Paragraphs arrived after we were waiting — start playing from the top
        this._stoppedByTimeout = false;
        await this.resetParagraphs();
        if (this._aborted) return;
        this._autoAdvancing = true;
        try {
          await this.play();
        } finally {
          this._autoAdvancing = false;
        }
        return;
      }
      if (this._aborted) return;
      if (this.playingState === PlayingState.Playing) {
        await this.handleLocationChanged();
      }
    };
    const onNextViewParagraphs = (paragraphs: ParagraphWithIndex[]) => {
      if (isEqual(this.nextPageParagraphs, paragraphs)) return;
      this.nextPageParagraphs = paragraphs;
    };
    const onPreviousViewParagraphs = (paragraphs: ParagraphWithIndex[]) => {
      if (isEqual(this.previousPageParagraphs, paragraphs)) return;
      this.previousPageParagraphs = [...paragraphs].reverse();
    };
    const onPageChanged = async () => {
      await this.handleLocationChanged();
    };

    eventBus.subscribe(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, onNewParagraphs);
    eventBus.subscribe(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, onNextViewParagraphs);
    eventBus.subscribe(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, onPreviousViewParagraphs);
    eventBus.subscribe(EventBusEvent.PAGE_CHANGED, onPageChanged);

    this.eventBusSubscriptions = [
      { event: EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, handler: onNewParagraphs },
      { event: EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, handler: onNextViewParagraphs },
      { event: EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, handler: onPreviousViewParagraphs },
      { event: EventBusEvent.PAGE_CHANGED, handler: onPageChanged },
    ];

    this.audioElement.onplay = async () => {
      eventBus.publish(
        EventBusEvent.PLAYING_AUDIO,
        await this.getCurrentParagraph()
      );
    };
  }

  private async resetParagraphs() {
    if (this.direction === Direction.Backward)
      await this.setParagraphIndex(this.currentViewParagraphs.length - 1);
    else await this.setParagraphIndex(0);
  }

  private handleLocationChanged = async () => {
    if (this._aborted) return;
    if (this.playingState === PlayingState.WaitingForNewParagraphs) {
      await this.resetParagraphs();
      // Don't call stop() or play() - let NEW_PARAGRAPHS_AVAILABLE handle resuming
      return;
    }
    if (this.playingState === PlayingState.Playing) {
      this.pause();
      await this.resetParagraphs();
      await this.play();
    } else {
      this.pause();
      await this.resetParagraphs();
    }
  };

  private removeEventBusSubscriptions() {
    for (const { event, handler } of this.eventBusSubscriptions) {
      eventBus.off(event as any, handler as any);
    }
    this.eventBusSubscriptions = [];
  }

  public cleanup() {
    this._aborted = true;
    if (this._prefetchTimer) {
      clearTimeout(this._prefetchTimer);
      this._prefetchTimer = null;
    }
    this._prefetchGeneration++;
    if (this._waitingTimeout) {
      clearTimeout(this._waitingTimeout);
      this._waitingTimeout = null;
    }
    this.removeEventBusSubscriptions();
    this.audioElement.removeEventListener("ended", this.handleEnded);
    this.audioElement.removeEventListener("error", this.handleError);
    this.audioElement.onplay = null;
    this.audioElement.pause();
    this.audioElement.src = "";
    this.setPlayingState(PlayingState.Stopped);
  }

  private handleEnded = async () => {
    if (this._aborted) return;
    const endedParagraph = await this.getCurrentParagraph();
    if (this._aborted) return;
    // Publish AUDIO_ENDED before next() so the highlight for the ended paragraph
    // is removed before the new paragraph's highlight is added via PLAYING_AUDIO.
    eventBus.publish(EventBusEvent.AUDIO_ENDED, endedParagraph);
    this._autoAdvancing = true;
    try {
      await this.next();
    } finally {
      this._autoAdvancing = false;
    }
  };
  private handleError = async (e: Event) => {
    const audioElement = e.target as HTMLAudioElement;
    const mediaError = audioElement.error;
    const currentParagraph = await this.getCurrentParagraph();
    // Detailed error information
    const errorDetails = {
      timestamp: new Date().toISOString(),
      eventType: e.type,
      src: audioElement.src,
      currentTime: audioElement.currentTime,
      duration: audioElement.duration,
      readyState: audioElement.readyState,
      networkState: audioElement.networkState,
      mediaError: mediaError
        ? {
            code: mediaError.code,
            message: mediaError.message,
            errorName: this.getMediaErrorName(mediaError.code),
          }
        : null,
      currentParagraph: currentParagraph
        ? {
            index: this.currentParagraphIndex,
            text: currentParagraph?.text.substring(0, 100) + "...",
            cfiRange: currentParagraph?.index,
          }
        : null,
    };

    console.error("🔴 Audio playback error - Full details:", errorDetails);
    console.error("🔴 Error event:", e);

    // Create detailed error message
    const errorMsg = mediaError
      ? `Audio error: ${this.getMediaErrorName(mediaError.code)} (${mediaError.message || "No message"})`
      : "Audio playback failed (unknown error)";

    this.errors.push(errorMsg);
    // Cap errors array to prevent unbounded growth during long sessions
    if (this.errors.length > 50) this.errors.shift();
    console.error("🔴 Error message added:", errorMsg);

    this.setPlayingState(PlayingState.Stopped);
  };

  private getMediaErrorName(code: number): string {
    const errorNames: Record<number, string> = {
      1: "MEDIA_ERR_ABORTED - Playback aborted by user",
      2: "MEDIA_ERR_NETWORK - Network error while loading",
      3: "MEDIA_ERR_DECODE - Decode error (corrupted or unsupported format)",
      4: "MEDIA_ERR_SRC_NOT_SUPPORTED - Media source not supported",
    };
    return errorNames[code] || `UNKNOWN_ERROR (code: ${code})`;
  }

  private getNetworkStateName(state: number): string {
    const stateNames: Record<number, string> = {
      0: "NETWORK_EMPTY - No data loaded",
      1: "NETWORK_IDLE - Media selected but not loading",
      2: "NETWORK_LOADING - Currently loading data",
      3: "NETWORK_NO_SOURCE - No valid source found",
    };
    return stateNames[state] || `UNKNOWN_STATE (${state})`;
  }

  private getReadyStateName(state: number): string {
    const stateNames: Record<number, string> = {
      0: "HAVE_NOTHING - No information available",
      1: "HAVE_METADATA - Metadata loaded",
      2: "HAVE_CURRENT_DATA - Current frame available",
      3: "HAVE_FUTURE_DATA - Future data available",
      4: "HAVE_ENOUGH_DATA - Enough data to play",
    };
    return stateNames[state] || `UNKNOWN_STATE (${state})`;
  }
  public async getCurrentParagraph() {
    this.currentParagraphIndex = Math.max(
      0,
      Math.min(
        this.currentParagraphIndex,
        this.currentViewParagraphs.length - 1
      )
    );
    return this.currentViewParagraphs[this.currentParagraphIndex];
  }
  public async getCurrentParagraphs() {
    return this.currentViewParagraphs;
  }
  public async getNextPageParagraphs() {
    return this.nextPageParagraphs;
  }
  public async getPreviousPageParagraphs() {
    return this.previousPageParagraphs;
  }

  public async play(maxRetries: number = 3): Promise<void> {
    if (this._aborted) return;
    logStateEvent("player.play", {
      paragraphCount: this.currentViewParagraphs.length,
      currentIndex: this.currentParagraphIndex,
      bookId: this.bookId,
    });
    // Remove any existing listeners first to prevent accumulation.
    // They will be re-added after setupEventListeners resolves (inside
    // playWithoutRetry) to avoid double-firing with the once-off setup listeners.
    this.audioElement.removeEventListener("ended", this.handleEnded);
    this.audioElement.removeEventListener("error", this.handleError);

    let attempt = 0;
    let skipCache = false;

    while (attempt < maxRetries) {
      if (this._aborted) return;
      try {
        // await this.clearHighlights();

        await this.playWithoutRetry(skipCache);

        return; // success
      } catch (err) {
        if (this._aborted) return;
        console.error(">>> Player: Play attempt failed", {
          attempt: attempt + 1,
          skipCache,
          err,
        });

        // Ensure a clean retry
        const currentParagraph = await this.getCurrentParagraph();
        if (currentParagraph) this.audioCache.delete(currentParagraph.index);
        this.audioElement.pause();
        this.audioElement.src = "";
        skipCache = true; // From now on bypass cache
        attempt += 1;
      }
    }
    if (this._aborted) return;
    console.error(">>> Player: All retries failed — skipping paragraph");
    await this.next();
  }

  public async playWithoutRetry(skipCache: boolean = false) {
    if (this._aborted) return;
    if (this.playingState === PlayingState.Playing) return;

    if (this.currentViewParagraphs.length === 0) {
      // If next page paragraphs are also empty, paragraphs likely haven't
      // loaded yet — wait for the event bus to deliver them instead of
      // entering an infinite moveToNextPage loop.
      if (this.nextPageParagraphs.length === 0) {
        console.warn(
          "🎵 No paragraphs available yet - waiting for paragraphs to load"
        );
        this.setPlayingState(PlayingState.WaitingForNewParagraphs);
        return;
      }
      console.warn(
        "🎵 No paragraphs on page (likely an image page) - pausing briefly then moving to next page"
      );
      // Give user 2 seconds to view the image, then move to next page
      await new Promise((resolve) => setTimeout(resolve, 2000));
      if (this._aborted) return;
      await this.moveToNextPage();
      return;
    }

    const currentParagraph = await this.getCurrentParagraph();
    if (!currentParagraph) {
      console.error("🎵 No current paragraph available");
      this.errors.push("No current paragraph available to play");
      return;
    }
    // Check if paragraph has no text (e.g., image-only content)
    if (!currentParagraph.text.trim()) {
      console.warn(
        "🎵 No text in paragraph (likely an image) - pausing briefly then moving to next paragraph"
      );
      await new Promise((resolve) => setTimeout(resolve, 2000));
      if (this._aborted) return;
      await this.next();
      return;
    }

    let audioFetched = false;

    // Set loading state while waiting for audio
    setTimeout(() => {
      if (!audioFetched) {
        this.setPlayingState(PlayingState.Loading);
      }
    }, 500); // delay before showing loading state

    // Request audio with high priority

    const audioPath = await this.requestAudio(
      currentParagraph,
      this.getNextPriority(),
      skipCache
    );
    audioFetched = true;

    // Check abort after async TTS fetch — cleanup may have been called while waiting
    if (this._aborted) return;

    if (!audioPath) {
      console.error("🎵 Failed to get audio path");
      this.errors.push("Failed to request audio");
      throw new Error("Failed to request audio");
    }

    this.audioElement.pause();
    this.audioElement.currentTime = 0;

    // Set new source and wait for it to be ready
    this.audioElement.src = audioPath;
    this.audioElement.load();

    await this.setupEventListeners(currentParagraph);

    // Add persistent listeners only after setup resolves — avoids
    // double-firing with the once-off error listener in setupEventListeners.
    this.audioElement.addEventListener("ended", this.handleEnded);
    this.audioElement.addEventListener("error", this.handleError);

    await this.audioElement.play();

    this.setPlayingState(PlayingState.Playing);

    // Debounce prefetch — if the user is rapidly skipping paragraphs,
    // we only prefetch for the paragraph they settle on.
    // During auto-advance (handleEnded → next → play), prefetch immediately.
    this.schedulePrefetch(this._autoAdvancing);
  }

  /**
   * Schedule a debounced prefetch for nearby paragraphs and page boundaries.
   * Each call cancels any pending prefetch so rapid navigation doesn't
   * trigger wasted TTS requests for intermediate paragraphs.
   *
   * @param immediate — if true, prefetch fires synchronously (delay=0).
   *   Used during continuous TTS playback (handleEnded → next → play).
   *   Manual next/prev calls go through stop() → play() which always
   *   passes through playWithoutRetry, so we use `immediate` to distinguish.
   */
  private schedulePrefetch(immediate: boolean = false) {
    if (this._prefetchTimer) clearTimeout(this._prefetchTimer);
    const generation = ++this._prefetchGeneration;

    // During continuous playback (immediate=true), prefetch right away so
    // the pipeline stays fed. During manual navigation, debounce to avoid
    // wasted TTS requests for intermediate pages the user is flipping past.
    const delay = immediate ? 0 : 200;

    this._prefetchTimer = setTimeout(() => {
      // Stale — user has navigated again since this was scheduled
      if (generation !== this._prefetchGeneration || this._aborted) return;

      // Prefetch nearby paragraphs on the current page
      void this.prefetchAudio(this.currentParagraphIndex + 1, 3, generation);
      void this.prefetchAudio(this.currentParagraphIndex - 3, 3, generation);

      // Prefetch across page boundaries for smooth prev/next page transitions
      if (this.currentParagraphIndex === 0) {
        void this.prefetchPrevPageAudio(3, generation);
      }
      if (this.currentParagraphIndex >= this.currentViewParagraphs.length - 1) {
        void this.prefetchNextPageAudio(3, generation);
      }
    }, delay);
  }
  async setupEventListeners(currentParagraph: ParagraphWithIndex) {
    await new Promise((resolve, reject) => {
      const handleCanPlay = () => {
        this.audioElement?.removeEventListener("canplaythrough", handleCanPlay);
        this.audioElement?.removeEventListener("error", handleError);
        resolve(undefined);
      };
      const handleError = async (e: Event) => {
        const audioElement = e.target as HTMLAudioElement;
        const mediaError = audioElement.error;

        const errorDetails = {
          timestamp: new Date().toISOString(),
          eventType: e.type,
          src: audioElement.src,
          readyState: audioElement.readyState,
          networkState: audioElement.networkState,
          networkStateName: this.getNetworkStateName(audioElement.networkState),
          readyStateName: this.getReadyStateName(audioElement.readyState),
          mediaError: mediaError
            ? {
                code: mediaError.code,
                message: mediaError.message,
                errorName: this.getMediaErrorName(mediaError.code),
              }
            : null,
          currentParagraph: {
            index: this.currentParagraphIndex,
            text: currentParagraph.text.substring(0, 100) + "...",
            cfiRange: currentParagraph.index,
          },
        };

        console.error("🔴 Audio load error - Full details:", errorDetails);
        console.error("🔴 Load error event:", e);

        this.audioElement?.removeEventListener("canplaythrough", handleCanPlay);
        this.audioElement?.removeEventListener("error", handleError);
        const p = await this.getCurrentParagraph();
        if (p) this.audioCache.delete(p.index);
        reject(new Error(JSON.stringify(errorDetails)));
      };
      this.audioElement?.addEventListener("canplaythrough", handleCanPlay, {
        once: true,
      });
      this.audioElement?.addEventListener("error", handleError, {
        once: true,
      });
    });
  }
  public pause() {
    if (this.audioElement.paused) return;
    this.audioElement.pause();

    this.setPlayingState(PlayingState.Paused);
  }
  public resume() {
    if (this.playingState !== PlayingState.Paused) return;
    this.audioElement.play().catch((error) => {
      console.error("Failed to resume audio:", error);
      this.errors.push(`Failed to resume audio: ${error.message}`);
    });
    this.setPlayingState(PlayingState.Playing);
  }
  private async getCurrentViewParagraphs() {
    return this.currentViewParagraphs;
  }

  public async setParagraphIndex(index: number) {
    const currentViewParagraphsLength = (await this.getCurrentViewParagraphs())
      .length;

    // if (index < 0) {
    //   index = 0;
    // }
    // if (index > currentViewParagraphsLength) {
    //   index = currentViewParagraphsLength - 1;
    // }
    index = Math.max(0, Math.min(index, currentViewParagraphsLength - 1));
    this.currentParagraphIndex = index;
    this.emit(PlayerEvent.PARAGRAPH_INDEX_CHANGED, {
      index,
      paragraph: await this.getCurrentParagraph(),
    });
  }
  public async stop() {
    if (this.playingState === PlayingState.Stopped) return;
    this.audioElement.pause();
    this.audioElement.currentTime = 0;
    // Transition out of Playing immediately, before any async work.
    // This prevents play() from being a no-op if stop() is called
    // but the async requestAudio below throws before reaching the
    // old setPlayingState(Stopped) at the end.
    this.setPlayingState(PlayingState.Stopped);
    await this.setParagraphIndex(0);

    if (this._aborted) return;
    const currentParagraph = await this.getCurrentParagraph();
    if (!currentParagraph) return;
    const audioPath =
      (await this.requestAudio(currentParagraph, this.getNextPriority())) || "";

    // Check abort after async request — cleanup may have been called while waiting
    if (this._aborted) return;

    // set the source to the first paragraph
    this.audioElement.src = audioPath || "";
    this.audioElement.load();
  }
  private prefetchNextPageAudio = (count: number = 3, generation?: number) => {
    if (this.nextPageParagraphs.length === 0) return;
    const promises: Promise<unknown>[] = [];
    for (let i = 0; i < Math.min(count, this.nextPageParagraphs.length); i++) {
      if (generation !== undefined && generation !== this._prefetchGeneration) return;
      const paragraph = this.nextPageParagraphs[i];

      const promise = this.requestAudio(
        paragraph,
        this.getPrefetchPriority()
      ).catch((error) => {
        console.warn(`Prefetch failed for next page paragraph ${i}:`, error);
      });
      promises.push(promise);
    }
    return Promise.all(promises);
  };
  private prefetchPrevPageAudio = (count: number = 3, generation?: number) => {
    if (this.previousPageParagraphs.length === 0) return;
    if (generation !== undefined && generation !== this._prefetchGeneration) return;
    const promises: Promise<unknown>[] = [];
    for (
      let i = 0;
      i < Math.min(count, this.previousPageParagraphs.length);
      i++
    ) {
      if (generation !== undefined && generation !== this._prefetchGeneration) break;
      const paragraph = this.previousPageParagraphs[i];
      promises.push(
        this.requestAudio(paragraph, this.getPrefetchPriority()).catch(
          (error) => {
            console.warn(`Prefetch failed for prev page paragraph ${i}:`, error);
          }
        )
      );
    }
    return Promise.all(promises);
  };
  private moveToNextPage = async () => {
    if (this._aborted) return;
    this.setPlayingState(PlayingState.WaitingForNewParagraphs);
    this.currentViewParagraphs = this.nextPageParagraphs;
    this.nextPageParagraphs = [];

    eventBus.publish(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED);

    // If we already have paragraphs from the prefetch, play immediately.
    // Otherwise, wait for NEW_PARAGRAPHS_AVAILABLE to arrive via the event bus
    // (the onNewParagraphs handler will resume playback).
    if (this._aborted) return;
    if (this.currentViewParagraphs.length > 0) {
      await this.stop();
      await this.resetParagraphs();
      await this.play();
    }
  };
  private moveToPreviousPage = async () => {
    if (this._aborted) return;
    this.setPlayingState(PlayingState.WaitingForNewParagraphs);
    this.currentViewParagraphs = [...this.previousPageParagraphs].reverse();
    this.previousPageParagraphs = [];

    eventBus.publish(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED);

    if (this._aborted) return;
    if (this.currentViewParagraphs.length > 0) {
      await this.stop();
      await this.resetParagraphs();
      await this.play();
    }
  };
  private updateParagaph = async (index: number) => {
    // bounds checks
    if (index < 0) {
      await this.moveToPreviousPage();
      return;
    }

    if (index >= this.currentViewParagraphs.length) {
      await this.moveToNextPage();
      return;
    }
    // first remove the current paragraph highlight and pause audio
    await this.stop();

    await this.setParagraphIndex(index);

    await this.play();
  };
  public prev = async () => {
    if (this._aborted) return;
    this.direction = Direction.Backward;
    const beforeMovedParagraph = await this.getCurrentParagraph();
    const prevIndex = this.currentParagraphIndex - 1;
    await this.updateParagaph(prevIndex);
    eventBus.publish(EventBusEvent.MOVED_TO_PREV_PARAGRAPH, {
      from: beforeMovedParagraph,
      to: await this.getCurrentParagraph(),
      direction: Direction.Backward,
    });
  };
  public next = async () => {
    if (this._aborted) return;
    this.direction = Direction.Forward;
    const beforeMovedParagraph = await this.getCurrentParagraph();
    const nextIndex = this.currentParagraphIndex + 1;

    await this.updateParagaph(nextIndex);
    eventBus.publish(EventBusEvent.MOVED_TO_NEXT_PARAGRAPH, {
      from: beforeMovedParagraph,
      to: await this.getCurrentParagraph(),
      direction: Direction.Forward,
    });
  };

  public getPlayingState() {
    return this.playingState;
  }
  public setPlayingState(playingState: PlayingState) {
    if (this.playingState === playingState) return;
    const prev = this.playingState;
    this.playingState = playingState;
    logStateEvent("player.stateChange", { from: prev, to: playingState });
    this.emit(PlayerEvent.PLAYING_STATE_CHANGED, playingState);
    eventBus.publish(EventBusEvent.PLAYING_STATE_CHANGED, playingState);

    // When entering WaitingForNewParagraphs, set a timeout to stop if no
    // paragraphs arrive (end of book). If paragraphs do arrive, the
    // onNewParagraphs handler transitions out of WaitingForNewParagraphs
    // which clears this timeout.
    if (playingState === PlayingState.WaitingForNewParagraphs) {
      if (this._waitingTimeout) clearTimeout(this._waitingTimeout);
      this._waitingTimeout = setTimeout(() => {
        if (this.playingState === PlayingState.WaitingForNewParagraphs) {
          this._stoppedByTimeout = true;
          this.setPlayingState(PlayingState.Stopped);
        }
      }, 10000); // 10s — MOBI/DJVU IPC fetches can take >3s on large chapters
    } else {
      if (this._waitingTimeout) {
        clearTimeout(this._waitingTimeout);
        this._waitingTimeout = null;
      }
    }
  }

  public getErrors() {
    return this.errors;
  }

  public async getDetailedErrorInfo() {
    const currentParagraph = await this.getCurrentParagraph();
    return {
      errors: this.errors,
      audioElementState: {
        src: this.audioElement.src,
        currentTime: this.audioElement.currentTime,
        duration: this.audioElement.duration,
        readyState: this.audioElement.readyState,
        readyStateName: this.getReadyStateName(this.audioElement.readyState),
        networkState: this.audioElement.networkState,
        networkStateName: this.getNetworkStateName(
          this.audioElement.networkState
        ),
        paused: this.audioElement.paused,
        ended: this.audioElement.ended,
        error: this.audioElement.error
          ? {
              code: this.audioElement.error.code,
              message: this.audioElement.error.message,
              errorName: this.getMediaErrorName(this.audioElement.error.code),
            }
          : null,
      },
      currentState: {
        playingState: this.playingState,
        paragraphIndex: this.currentParagraphIndex,
        totalParagraphs: this.currentViewParagraphs.length,
        currentParagraph: currentParagraph
          ? {
              text: currentParagraph?.text.substring(0, 100) + "...",
              cfiRange: currentParagraph?.index,
            }
          : null,
      },
      cacheInfo: {
        cacheSize: this.audioCache.size,
        cachedRanges: Array.from(this.audioCache.keys()),
      },
    };
  }

  public clearErrors() {
    this.errors = [];
  }

  private getNextPriority() {
    this.priority = this.priority + 1;
    return this.priority;
  }
  private getPrefetchPriority() {
    return this.priority - 1;
  }

  public async requestAudio(
    paragraph: ParagraphWithIndex,
    priority: number,
    skipCache = false
  ) {
    if (skipCache === false) {
      if (!paragraph.text.trim()) {
        return null;
      }

      const cached = this.audioCache.get(paragraph.index);
      if (cached) {
        return cached;
      }

      // Check disk cache via direct API call
      try {
        const diskCached = await getTTSAudioPath(
          this.bookId.toString(),
          paragraph.index
        );

        if (diskCached) {
          this.addToAudioCache(paragraph.index, diskCached);

          return diskCached;
        }
      } catch (error) {
        console.error(">>> Player: Cache check failed with error:", {
          error:
            error instanceof Error
              ? {
                  name: error.name,
                  message: error.message,
                  stack: error.stack,
                }
              : String(error),
          paragraph: {
            cfiRange: paragraph.index,
            textPreview: paragraph.text.substring(0, 50) + "...",
          },
        });
      }

      // Request new audio via React Query mutation
    }
    try {
      const audioPath = await requestTTSAudio(
        this.bookId.toString(),
        paragraph.index,
        paragraph.text,
        priority
      );

      // Update cache
      this.addToAudioCache(paragraph.index, audioPath);

      return audioPath;
    } catch (error) {
      console.error(">>> Player: Audio request failed:", {
        error:
          error instanceof Error
            ? {
                name: error.name,
                message: error.message,
                stack: error.stack,
              }
            : String(error),
        paragraph: {
          cfiRange: paragraph.index,
          textPreview: paragraph.text.substring(0, 50) + "...",
        },
      });
      throw error;
    }
  }
  addToAudioCache(cfiRange: string, audioPath: string) {
    this.audioCache.set(cfiRange, audioPath);
  }

  private async prefetchAudio(startIndex: number, count: number, generation?: number) {
    if (generation !== undefined && generation !== this._prefetchGeneration) return;
    const fetches: Promise<unknown>[] = [];
    for (let i = 0; i < count; i++) {
      const index = startIndex + i;
      if (index >= 0 && index < this.currentViewParagraphs.length) {
        const paragraph = this.currentViewParagraphs[index];
        fetches.push(
          this.requestAudio(paragraph, this.priority - 1).catch((error) => {
            console.warn(`Prefetch failed for paragraph ${index}:`, error);
          })
        );
      }
    }
    await Promise.all(fetches);
  }
}
