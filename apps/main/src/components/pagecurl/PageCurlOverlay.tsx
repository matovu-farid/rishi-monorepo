// apps/main/src/components/pagecurl/PageCurlOverlay.tsx

import { useEffect, useRef } from "react";
import { drawPageCurl, type CurlDirection } from "./drawPageCurl";

interface Props {
  progress: number;
  direction: CurlDirection;
  pageColor: string;
}

export function PageCurlOverlay({ progress, direction, pageColor }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const parent = canvas.parentElement;
    if (!parent) return;

    const { width: W, height: H } = parent.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    canvas.width = W * dpr;
    canvas.height = H * dpr;

    const rawCtx = canvas.getContext("2d");
    if (!rawCtx) return;
    const ctx: CanvasRenderingContext2D = rawCtx;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    drawPageCurl(ctx, W, H, progress, direction, pageColor);
  }, [progress, direction, pageColor]);

  return (
    <canvas
      ref={canvasRef}
      style={{
        position: "absolute",
        top: 0,
        left: 0,
        width: "100%",
        height: "100%",
        pointerEvents: "none",
        zIndex: 10,
      }}
    />
  );
}
