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
    }
  }
})
