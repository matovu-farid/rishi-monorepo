// apps/main/src/components/pagecurl/usePageCurl.ts

import { useCallback, useRef, useState } from "react";
import type { CurlDirection } from "./drawPageCurl";

export type CurlState = "idle" | "dragging" | "animating";

export interface PageCurlResult {
  progress: number;
  direction: CurlDirection;
  active: boolean;
  pointerHandlers: {
    onPointerDown: (e: React.PointerEvent) => void;
    onPointerMove: (e: React.PointerEvent) => void;
    onPointerUp: (e: React.PointerEvent) => void;
    onPointerCancel: (e: React.PointerEvent) => void;
  };
  autoTurn: (dir: CurlDirection) => void;
}

const EDGE_ZONE = 60;
const COMMIT_THRESHOLD = 0.35;
const AUTO_DURATION = 350;
const SNAP_DURATION = 200;

function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

export function usePageCurl(callbacks: {
  onNavigate: (dir: CurlDirection) => void;
  onUndoNavigate: (dir: CurlDirection) => void;
}): PageCurlResult {
  const [active, setActive] = useState(false);
  const progressRef = useRef(0);
  const directionRef = useRef<CurlDirection>("right");
  const stateRef = useRef<CurlState>("idle");
  const rafRef = useRef<number | null>(null);
  const containerWidthRef = useRef(0);
  const dragStartXRef = useRef(0);
  const navigatedRef = useRef(false);
  const [, forceRender] = useState(0);
  const kick = useCallback(() => forceRender((n) => n + 1), []);

  const callbacksRef = useRef(callbacks);
  callbacksRef.current = callbacks;

  const cancelRaf = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
  }, []);

  const animateTo = useCallback(
    (target: number, duration: number, onDone: () => void) => {
      cancelRaf();
      const start = progressRef.current;
      const startTime = performance.now();
      stateRef.current = "animating";

      function tick(now: number) {
        const elapsed = now - startTime;
        const rawT = Math.min(elapsed / duration, 1);
        const t = easeOutCubic(rawT);
        progressRef.current = start + (target - start) * t;
        kick();

        if (rawT < 1) {
          rafRef.current = requestAnimationFrame(tick);
        } else {
          progressRef.current = target;
          rafRef.current = null;
          onDone();
        }
      }

      rafRef.current = requestAnimationFrame(tick);
    },
    [cancelRaf, kick],
  );

  const finish = useCallback(
    (completed: boolean) => {
      const dir = directionRef.current;
      if (!completed && navigatedRef.current) {
        callbacksRef.current.onUndoNavigate(dir);
      }
      stateRef.current = "idle";
      progressRef.current = 0;
      navigatedRef.current = false;
      setActive(false);
      kick();
    },
    [kick],
  );

  const commitOrCancel = useCallback(() => {
    if (progressRef.current >= COMMIT_THRESHOLD) {
      animateTo(1, SNAP_DURATION, () => finish(true));
    } else {
      animateTo(0, SNAP_DURATION, () => finish(false));
    }
  }, [animateTo, finish]);

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (stateRef.current !== "idle") return;
      const rect = e.currentTarget.getBoundingClientRect();
      const x = e.clientX - rect.left;
      containerWidthRef.current = rect.width;

      const nearRight = x > rect.width - EDGE_ZONE;
      const nearLeft = x < EDGE_ZONE;
      if (!nearRight && !nearLeft) return;

      e.currentTarget.setPointerCapture(e.pointerId);

      const dir: CurlDirection = nearRight ? "right" : "left";
      directionRef.current = dir;
      dragStartXRef.current = e.clientX;
      stateRef.current = "dragging";
      progressRef.current = 0;

      callbacksRef.current.onNavigate(dir);
      navigatedRef.current = true;

      setActive(true);
      kick();
    },
    [kick],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (stateRef.current !== "dragging") return;
      const dx = e.clientX - dragStartXRef.current;
      const W = containerWidthRef.current;
      if (W === 0) return;

      const isForward = directionRef.current === "right";
      const raw = isForward ? -dx / W : dx / W;
      progressRef.current = Math.max(0, Math.min(1, raw));
      kick();
    },
    [kick],
  );

  const onPointerUp = useCallback(
    (_e: React.PointerEvent) => {
      if (stateRef.current !== "dragging") return;
      commitOrCancel();
    },
    [commitOrCancel],
  );

  const onPointerCancel = useCallback(
    (_e: React.PointerEvent) => {
      if (stateRef.current !== "dragging") return;
      commitOrCancel();
    },
    [commitOrCancel],
  );

  const autoTurn = useCallback(
    (dir: CurlDirection) => {
      if (stateRef.current !== "idle") return;
      cancelRaf();
      directionRef.current = dir;
      progressRef.current = 0;
      stateRef.current = "animating";
      navigatedRef.current = true;
      setActive(true);
      kick();

      callbacksRef.current.onNavigate(dir);

      animateTo(1, AUTO_DURATION, () => finish(true));
    },
    [cancelRaf, kick, animateTo, finish],
  );

  return {
    progress: progressRef.current,
    direction: directionRef.current,
    active,
    pointerHandlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel,
    },
    autoTurn,
  };
}
