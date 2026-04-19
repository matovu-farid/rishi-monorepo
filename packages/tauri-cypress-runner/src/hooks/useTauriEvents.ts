import { useEffect } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export function useTauriEvent<T>(event: string, callback: (payload: T) => void) {
  useEffect(() => {
    let unlisten: UnlistenFn | undefined;
    listen<T>(event, (e) => callback(e.payload)).then((fn) => { unlisten = fn; });
    return () => { unlisten?.(); };
  }, [event, callback]);
}
