import { bridge } from "../bridge.js";

export async function winResize(width: number, height: number): Promise<void> {
  await bridge.invoke("plugin:test-harness|resize_window", { width, height });
}

export async function winMinimize(): Promise<void> {
  await bridge.invoke("plugin:test-harness|minimize_window");
}

export async function winMaximize(): Promise<void> {
  await bridge.invoke("plugin:test-harness|maximize_window");
}

export async function winFullscreen(enabled: boolean = true): Promise<void> {
  await bridge.invoke("plugin:test-harness|fullscreen_window", { fullscreen: enabled });
}

export async function winPosition(): Promise<{ x: number; y: number }> {
  return bridge.invoke("plugin:test-harness|get_window_position") as Promise<{ x: number; y: number }>;
}

export async function winSize(): Promise<{ width: number; height: number }> {
  return bridge.invoke("plugin:test-harness|get_window_size") as Promise<{ width: number; height: number }>;
}
