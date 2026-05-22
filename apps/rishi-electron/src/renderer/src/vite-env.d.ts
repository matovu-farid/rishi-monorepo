/// <reference types="vite/client" />

interface ImportMetaEnv {
  // Better Auth runs entirely in the main process, so the renderer needs no
  // auth-related VITE_ keys.
  //
  // VITE_WORKER_URL: override for the sync/AI worker base URL. Used by
  // `src/renderer/src/config/worker-url.ts` so the cross-platform sync E2E
  // test can repoint every renderer fetch at a local `wrangler dev` instance.
  // Unset in production — the renderer falls back to `https://api.fidexa.org`.
  readonly VITE_WORKER_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
