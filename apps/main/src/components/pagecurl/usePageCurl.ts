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
const COMMIT_THRESHOLD = 0.3;
const AUTO_DURATION = 200;
const SNAP_DURATION = 120;
const VELOCITY_COMMIT = 1.2; // progress/sec — flick to commit

function easeOutQuart(t: number): number {
  return 1 - Math.pow(1 - t, 4);
}

export function usePageCurl(callbacks: {
  /** Return false to reject the navigation (e.g. nav machine busy). */
  onNavigate: (dir: CurlDirection) => boolean;
  onCommit: (dir: CurlDirection) => void;
  onUndoNavigate: (dir: CurlDirection) => void;
}): PageCurlResult {
  const [active, setActive] = useState(false);
  const progressRef = useRef(0);
  const directionRef = useRef<CurlDirection>("right");
  const stateRef = useRef<CurlState>("idle");
  const rafRef = useRef<number | null>(null);
  const containerRectRef = useRef<DOMRect | null>(null);
  const navigatedRef = useRef(false);
  // Velocity tracking
  const lastMoveTimeRef = useRef(0);
  const lastProgressRef = useRef(0);
  const velocityRef = useRef(0);
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
        const t = easeOutQuart(rawT);
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
      if (completed && navigatedRef.current) {
        callbacksRef.current.onCommit(dir);
      } else if (!completed && navigatedRef.current) {
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
    const p = progressRef.current;
    const v = velocityRef.current;
    // Commit if past threshold or if user flicked forward
    if (p >= COMMIT_THRESHOLD || v > VELOCITY_COMMIT) {
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

      const nearRight = x > rect.width - EDGE_ZONE;
      const nearLeft = x < EDGE_ZONE;
      if (!nearRight && !nearLeft) return;

      const dir: CurlDirection = nearRight ? "right" : "left";

      // Ask the navigation system before starting the gesture
      if (!callbacksRef.current.onNavigate(dir)) return;

      e.currentTarget.setPointerCapture(e.pointerId);
      directionRef.current = dir;
      containerRectRef.current = rect;
      stateRef.current = "dragging";

      // Position-based: fold starts right at finger position
      const W = rect.width;
      const raw = dir === "right" ? 1 - x / W : x / W;
      progressRef.current = Math.max(0, Math.min(1, raw));

      // Reset velocity tracking
      velocityRef.current = 0;
      lastMoveTimeRef.current = performance.now();
      lastProgressRef.current = progressRef.current;

      navigatedRef.current = true;
      setActive(true);
      kick();
    },
    [kick],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (stateRef.current !== "dragging") return;
      const rect = containerRectRef.current;
      if (!rect) return;

      const x = e.clientX - rect.left;
      const W = rect.width;

      const isForward = directionRef.current === "right";
      const raw = isForward ? 1 - x / W : x / W;
      const newProgress = Math.max(0, Math.min(1, raw));

      // Velocity tracking (exponential smoothing)
      const now = performance.now();
      const dt = now - lastMoveTimeRef.current;
      if (dt > 0 && dt < 100) {
        const instant = ((newProgress - lastProgressRef.current) / dt) * 1000;
        velocityRef.current = 0.7 * instant + 0.3 * velocityRef.current;
      }
      lastMoveTimeRef.current = now;
      lastProgressRef.current = newProgress;

      progressRef.current = newProgress;
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

      // Ask the navigation system before starting the animation
      if (!callbacksRef.current.onNavigate(dir)) return;

      cancelRaf();
      directionRef.current = dir;
      progressRef.current = 0;
      stateRef.current = "animating";
      navigatedRef.current = true;
      setActive(true);
      kick();

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
