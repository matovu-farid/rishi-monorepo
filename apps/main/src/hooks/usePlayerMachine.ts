// apps/main/src/hooks/usePlayerMachine.ts
import { useEffect, useRef } from "react";
import { createActor } from "xstate";
import { playerMachine } from "@/machines/playerMachine";
import { usePlayerStore } from "@/stores/playerStore";
import { AudioService } from "@/services/audioService";
import audio from "@/models/audio";
import type { PlayerStoreState } from "@/stores/playerStore";
import { logStateEvent } from "@/utils/stateDump";
import { publishCurrentEpubParagraphs } from "@/stores/epubStore";
import { usePdfStore } from "@/stores/pdfStore";
import { pageDataToParagraphs } from "@/components/pdf/utils/getPageParagraphs";

// Singleton audio service — owns the HTMLAudioElement
const audioService = new AudioService(audio);

// Map XState machine state value to PlayerStoreState string
function mapStateValue(value: string | Record<string, string>): PlayerStoreState {
  if (typeof value === "string") return value as PlayerStoreState;
  // Compound state: { paused: "clean" } → "paused.clean"
  const [parent, child] = Object.entries(value)[0];
  return `${parent}.${child}` as PlayerStoreState;
}

export function usePlayerMachine(bookId: string) {
  const actorRef = useRef<ReturnType<typeof createActor<typeof playerMachine>> | null>(null);

  useEffect(() => {
    // Create and start the machine actor
    const actor = createActor(playerMachine);
    actorRef.current = actor;

    // --- 1. Machine → store sync ---
    const machineUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value);
      const ctx = snapshot.context;
      const currentParagraph =
        ctx.currentParagraphs[ctx.paragraphIndex] ?? null;

      logStateEvent("player.stateChange", {
        from: usePlayerStore.getState().playingState,
        to: state,
      });

      usePlayerStore.setState({
        playingState: state,
        activeParagraph:
          state === "playing" ? currentParagraph : usePlayerStore.getState().activeParagraph,
        errors: ctx.errors,
      });
    });

    // --- 2. Store send reference (updated below with wrappedSend) ---

    // --- 3. Store → machine sync (paragraphs) ---
    const unsubCurrent = usePlayerStore.subscribe(
      (s) => s.currentParagraphs,
      (paragraphs) => {
        actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs });
      }
    );
    const unsubNext = usePlayerStore.subscribe(
      (s) => s.nextPageParagraphs,
      (paragraphs) => {
        actor.send({ type: "NEXT_PARAGRAPHS_UPDATED", paragraphs });
      }
    );
    const unsubPrev = usePlayerStore.subscribe(
      (s) => s.prevPageParagraphs,
      (paragraphs) => {
        actor.send({ type: "PREV_PARAGRAPHS_UPDATED", paragraphs });
      }
    );

    // --- 4. Machine actions → audioService side effects ---
    let prevState = "";
    // Generation counter to cancel stale fetches when a new loading entry fires
    let fetchGeneration = 0;
    const audioUnsub = actor.subscribe((snapshot) => {
      const state = mapStateValue(snapshot.value);
      const ctx = snapshot.context;
      const paragraph = ctx.currentParagraphs[ctx.paragraphIndex];

      if (state === "loading") {
        // Entering or re-entering loading (includes retries via reenter: true).
        // Increment generation so any in-flight fetch from a previous attempt
        // is ignored when it resolves.
        const gen = ++fetchGeneration;
        const wasPlaying = prevState === "playing";
        if (paragraph) {
          audioService
            .fetchAudio(ctx.bookId, paragraph, ctx.retryCount > 0)
            .then((path) => {
              if (gen !== fetchGeneration) return; // stale
              return audioService.loadAndPlay(path);
            })
            .then(() => {
              if (gen !== fetchGeneration) return; // stale
              actor.send({ type: "AUDIO_LOADED" });
              // Update activeParagraph now that audio is playing
              usePlayerStore.setState({ activeParagraph: paragraph });
              // Prefetch
              audioService.schedulePrefetch(
                ctx.paragraphIndex,
                ctx.currentParagraphs,
                ctx.nextPageParagraphs,
                ctx.prevPageParagraphs,
                ctx.bookId,
                wasPlaying // immediate if auto-advancing
              );
            })
            .catch((err) => {
              if (gen !== fetchGeneration) return; // stale
              console.error("Audio fetch/load failed:", err);
              audioService.deleteCacheEntry(paragraph.index);
              const msg = err instanceof Error ? err.message : String(err);
              actor.send({ type: "AUDIO_ERROR", error: msg });
            });
        }
      } else {
        // Left loading state — invalidate any in-flight fetch
        fetchGeneration++;
      }

      if (state === "playing" && prevState.startsWith("paused.clean")) {
        // Resume from clean pause
        void audioService.resumeAudio();
      }

      if (state.startsWith("paused") && prevState === "playing") {
        audioService.pauseAudio();
      }

      if (state === "stopped" && prevState !== "stopped" && prevState !== "idle") {
        audioService.stopAudio();
        usePlayerStore.setState({
          activeParagraph: null,
          endedParagraph: null,
        });
      }

      if (state === "waitingForParagraphs") {
        audioService.stopAudio();
        usePlayerStore.setState({
          pageRequest: "next",
        });
      }

      if (state === "idle" && prevState !== "idle") {
        audioService.cleanup();
        usePlayerStore.setState({
          activeParagraph: null,
          endedParagraph: null,
          lastMove: null,
          errors: [],
          pageRequest: null,
        });
      }

      prevState = state;
    });

    // --- 5. Track NEXT/PREV moves for highlight removal ---
    const originalSend = actor.send.bind(actor);
    const wrappedSend = (event: any) => {
      if (event.type === "NEXT" || event.type === "PREV") {
        const ctx = actor.getSnapshot().context;
        const fromParagraph = ctx.currentParagraphs[ctx.paragraphIndex] ?? null;
        originalSend(event);
        const newCtx = actor.getSnapshot().context;
        const toParagraph = newCtx.currentParagraphs[newCtx.paragraphIndex] ?? null;
        if (fromParagraph && toParagraph) {
          usePlayerStore.setState({
            lastMove: {
              from: fromParagraph,
              to: toParagraph,
              direction: event.type === "NEXT" ? "forward" : "backward",
            },
          });
        }
        return;
      }
      originalSend(event);
    };
    usePlayerStore.getState().setSend(wrappedSend);

    // --- 6. AudioService → machine callbacks ---
    audioService.onAudioEnded = () => {
      const ctx = actor.getSnapshot().context;
      const endedParagraph = ctx.currentParagraphs[ctx.paragraphIndex] ?? null;
      usePlayerStore.setState({ endedParagraph });
      actor.send({ type: "AUDIO_ENDED" });
    };
    audioService.onAudioError = (error) => {
      actor.send({
        type: "AUDIO_ERROR",
        error: error?.message ?? "Audio playback error",
      });
    };

    // --- Start actor and initialize ---
    actor.start();
    actor.send({ type: "INITIALIZE", bookId });

    // Seed paragraphs: re-publish from epub/PDF stores so the machine
    // receives paragraphs that may have been published before it subscribed.
    publishCurrentEpubParagraphs();
    const pdfState = usePdfStore.getState();
    const pdfPageData = pdfState.pageNumberToPageData[pdfState.pageNumber];
    if (pdfPageData) {
      const paragraphs = pageDataToParagraphs(pdfState.pageNumber, pdfPageData);
      usePlayerStore.getState().setCurrentParagraphs(paragraphs);
    }

    // Also forward any paragraphs already in the store
    const currentParagraphs = usePlayerStore.getState().currentParagraphs;
    if (currentParagraphs.length > 0) {
      actor.send({ type: "PARAGRAPHS_UPDATED", paragraphs: currentParagraphs });
    }

    return () => {
      actor.send({ type: "CLEANUP" });
      machineUnsub.unsubscribe();
      audioUnsub.unsubscribe();
      unsubCurrent();
      unsubNext();
      unsubPrev();
      usePlayerStore.getState().setSend(() => {});
      audioService.cleanup();
      actor.stop();
      actorRef.current = null;
    };
  }, [bookId]);

  return {
    send: actorRef.current?.send.bind(actorRef.current) ?? (() => {}),
  };
}
