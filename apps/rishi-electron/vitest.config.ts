import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  test: {
    globals: true,
    environment: 'happy-dom',
    include: ['src/**/*.test.{ts,tsx}'],
    exclude: ['**/node_modules/**', '**/out/**'],
    setupFiles: ['./src/renderer/src/test-setup.ts']
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src/renderer/src'),
      '@components': path.resolve(__dirname, 'src/renderer/src/components')
    },
    // Resolve through the symlinked workspace member path
    // (apps/rishi-electron/node_modules/@rishi/shared/...) rather than the
    // real path (packages/shared/...). This makes Vite walk up into
    // apps/rishi-electron/node_modules where electron's hoisted deps
    // (md5, xstate, epubjs, ...) live. Without this, Vite walks up from
    // packages/shared/node_modules/ and fails because shared's
    // .npmrc-hoisted layout isolates electron's deps from the shared tree.
    preserveSymlinks: true
  }
})
