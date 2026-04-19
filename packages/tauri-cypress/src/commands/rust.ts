import { bridge } from "../bridge.js";

export async function rustHelper(
  name: string,
  args?: unknown
): Promise<unknown> {
  return bridge.callHelper(name, args);
}

export async function rustAppState(key: string): Promise<unknown> {
  return bridge.getState(key);
}
