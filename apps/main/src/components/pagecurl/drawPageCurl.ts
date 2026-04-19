export type CurlDirection = "left" | "right";

export function drawPageCurl(
  ctx: CanvasRenderingContext2D,
  W: number,
  H: number,
  progress: number,
  direction: CurlDirection,
  pageColor: string,
): void {
  const isForward = direction === "right";
  const t = Math.max(0, Math.min(1, progress));

  ctx.clearRect(0, 0, W, H);

  const foldX = isForward ? W * (1 - t) : W * t;
  const maxCurl = W * 0.28;
  const curlW = Math.sin(t * Math.PI) * maxCurl;

  // 1. Flat page (gradient transparency near fold to reveal content underneath)
  ctx.save();
  ctx.beginPath();
  if (isForward) {
    ctx.rect(0, 0, foldX, H);
  } else {
    ctx.rect(foldX, 0, W - foldX, H);
  }
  ctx.clip();
  ctx.fillStyle = pageColor;
  ctx.fillRect(0, 0, W, H);
  // Erase near the fold so underlying content peeks through
  ctx.globalCompositeOperation = "destination-out";
  const eraseGrad = isForward
    ? ctx.createLinearGradient(0, 0, foldX, 0)
    : ctx.createLinearGradient(W, 0, foldX, 0);
  eraseGrad.addColorStop(0, "rgba(0,0,0,0)");
  eraseGrad.addColorStop(0.5, "rgba(0,0,0,0)");
  eraseGrad.addColorStop(1, "rgba(0,0,0,0.45)");
  ctx.fillStyle = eraseGrad;
  ctx.fillRect(0, 0, W, H);
  ctx.restore();

  if (curlW <= 1) return;

  // 2. Outer shadow
  const shadowW = Math.min(curlW * 0.7, 45);
  ctx.save();
  const outerGrad = isForward
    ? ctx.createLinearGradient(foldX, 0, foldX + shadowW, 0)
    : ctx.createLinearGradient(foldX, 0, foldX - shadowW, 0);
  outerGrad.addColorStop(0, "rgba(0,0,0,0.18)");
  outerGrad.addColorStop(0.35, "rgba(0,0,0,0.06)");
  outerGrad.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = outerGrad;
  if (isForward) {
    ctx.fillRect(foldX, 0, shadowW, H);
  } else {
    ctx.fillRect(foldX - shadowW, 0, shadowW, H);
  }
  ctx.restore();

  // 3. Curl shadow
  if (curlW > 3) {
    ctx.save();
    const cShadowW = curlW * 0.35;
    const edge = isForward ? foldX - curlW : foldX + curlW;
    const cs = isForward
      ? ctx.createLinearGradient(edge + cShadowW, 0, edge, 0)
      : ctx.createLinearGradient(edge - cShadowW, 0, edge, 0);
    cs.addColorStop(0, "rgba(0,0,0,0)");
    cs.addColorStop(1, "rgba(0,0,0,0.07)");
    ctx.fillStyle = cs;
    if (isForward) {
      ctx.fillRect(edge, 0, cShadowW, H);
    } else {
      ctx.fillRect(edge - cShadowW, 0, cShadowW, H);
    }
    ctx.restore();
  }

  // 4. Page curl with bezier edge
  ctx.save();
  ctx.beginPath();
  const curlEdge = isForward ? foldX - curlW : foldX + curlW;
  const bulge = isForward ? -curlW * 0.1 : curlW * 0.1;
  ctx.moveTo(foldX, 0);
  ctx.lineTo(foldX, H);
  ctx.lineTo(curlEdge, H);
  ctx.bezierCurveTo(curlEdge + bulge, H * 0.65, curlEdge + bulge, H * 0.35, curlEdge, 0);
  ctx.closePath();
  ctx.clip();

  ctx.fillStyle = pageColor;
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = "rgba(0,0,0,0.04)";
  ctx.fillRect(0, 0, W, H);

  const curlGrad = isForward
    ? ctx.createLinearGradient(foldX, 0, foldX - curlW, 0)
    : ctx.createLinearGradient(foldX, 0, foldX + curlW, 0);
  curlGrad.addColorStop(0, "rgba(0,0,0,0.10)");
  curlGrad.addColorStop(0.12, "rgba(255,255,255,0.10)");
  curlGrad.addColorStop(0.35, "rgba(0,0,0,0.01)");
  curlGrad.addColorStop(0.75, "rgba(0,0,0,0.04)");
  curlGrad.addColorStop(1, "rgba(0,0,0,0.14)");
  ctx.fillStyle = curlGrad;
  ctx.fillRect(0, 0, W, H);
  ctx.restore();

  // 5. Fold crease
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(foldX, 0);
  ctx.lineTo(foldX, H);
  ctx.strokeStyle = "rgba(255,255,255,0.18)";
  ctx.lineWidth = 1;
  ctx.stroke();
  ctx.restore();

  ctx.save();
  ctx.beginPath();
  ctx.moveTo(foldX + (isForward ? 1 : -1), 0);
  ctx.lineTo(foldX + (isForward ? 1 : -1), H);
  ctx.strokeStyle = "rgba(0,0,0,0.06)";
  ctx.lineWidth = 0.5;
  ctx.stroke();
  ctx.restore();
}
