// apps/main/src/hooks/useNavMachine.ts
//
// Creates the navigation xstate actor, wires it to the current epub
// rendition, and publishes its `send` function to the navStore so every
// component can dispatch navigation events.

import { useEffect, useRef } from "react";
import { createActor } from "xstate";
import { navMachine } from "@/machines/navMachine";
import type { NavState } from "@/machines/navMachine";
import { useNavStore } from "@/stores/navStore";
import type { Rendition } from "epubjs/types";

/**
 * Boot the navigation state machine for the current EPUB rendition.
 *
 * The hook subscribes to state transitions and executes the corresponding
 * rendition calls (next / prev / display).  A version counter in the
 * machine's context lets us detect re-entries (e.g. DISPLAY while
 * already navigating) without relying on `snapshot.event`.
 */
export function useNavMachine(rendition: Rendition | null) {
  const renditionRef = useRef(rendition);
  renditionRef.current = rendition;

  useEffect(() => {
    if (!rendition) return;

    const actor = createActor(navMachine);

    let lastHandledVersion = -1; // tracks which context.version we last acted on
    let navGen = 0; // guards stale SETTLED events

    // ── State → side-effect subscriber ─────────────────────────────
    const sub = actor.subscribe((snapshot) => {
      const state = snapshot.value as NavState;
      const ctx = snapshot.context;
      const r = renditionRef.current;

      // Always keep the store in sync
      useNavStore.getState().setNavState(state);

      // Only execute side-effects for *new* navigation transitions
      // (version is bumped by every action that needs a rendition call).
      if (!r || ctx.version <= lastHandledVersion) return;
      lastHandledVersion = ctx.version;

      // Entering "navigating" — call rendition.next / prev / display
      if (state === "navigating") {
        const gen = ++navGen;
        const settle = () => {
          if (gen === navGen) actor.send({ type: "SETTLED" });
        };

        let promise: Promise<void>;
        if (ctx.pendingAction === "next") {
          promise = r.next();
        } else if (ctx.pendingAction === "prev") {
          promise = r.prev();
        } else {
          promise = r.display(ctx.pendingLocation!);
        }
        promise.then(settle, settle);
      }

      // Entering "curling" — the curl animation owns visual timing,
      // but we track the rendition promise so SETTLED fires when it
      // resolves.  The machine stores this in `curlSettled` so
      // CURL_COMMIT can skip the settling wait if it already resolved.
      if (state === "curling") {
        const gen = ++navGen; // invalidate any in-flight navigating promise
        const settle = () => {
          if (gen === navGen) actor.send({ type: "SETTLED" });
        };
        const promise =
          ctx.curlDirection === "next" ? r.next() : r.prev();
        promise.then(settle, settle);
      }

      // Entering "undoing" — reverse the cancelled curl
      if (state === "undoing") {
        const gen = ++navGen;
        const settle = () => {
          if (gen === navGen) actor.send({ type: "SETTLED" });
        };
        const promise =
          ctx.pendingAction === "next" ? r.next() : r.prev();
        promise.then(settle, settle);
      }
    });

    // ── Publish send to the store BEFORE starting the actor so
    //    any component reacting to the initial state change can
    //    already dispatch events. ─────────────────────────────────
    const send = actor.send.bind(actor);
    useNavStore.getState().setSend(send);
    actor.start();

    return () => {
      sub.unsubscribe();
      actor.stop();
      // null (not a no-op fn) so the `!send` guard in
      // tryConsumePageRequest rejects events fired by the
      // synchronous setNavState("idle") subscriber below.
      useNavStore.getState().setSend(null);
      useNavStore.getState().setNavState("idle");
    };
  }, [rendition]);
}
