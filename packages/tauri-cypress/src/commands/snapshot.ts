import { bridge } from "../bridge.js";
import type { DomSnapshot } from "../types.js";

export function snapshotTake(label: string): DomSnapshot {
  return bridge.takeSnapshot(label);
}

export function snapshotScreenshot(name?: string): DomSnapshot {
  return bridge.takeSnapshot(name ?? `screenshot-${Date.now()}`);
}
