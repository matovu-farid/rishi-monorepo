/**
 * Shared voice-chat types. Ported verbatim from
 * `apps/rishi-electron/src/renderer/src/services/voice-chat/types.ts`
 * with the electron-only `@/services/rag`, `@/services/connectivity`,
 * `@/lib/api`, `@/lib/visualHeuristic`, `@/modules/pageCapture`
 * imports replaced by structural shapes declared inline, so the module
 * can be consumed by Electron and React Native alike without dragging
 * platform-specific code paths.
 */
export class OfflineError extends Error {
    name = 'OfflineError';
    constructor() {
        super('You are offline. Voice chat is unavailable until you reconnect.');
    }
}
