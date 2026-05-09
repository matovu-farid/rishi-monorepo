/// <reference types="vite/client" />

interface ImportMetaEnv {
  // No app-specific Vite env vars currently — Better Auth runs entirely
  // in the main process, so the renderer needs no auth-related VITE_ keys.
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
