/// <reference types="vite/client" />
interface ImportMetaEnv {
  readonly RENDERER_VITE_KEY: string
  // more env variables...
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
