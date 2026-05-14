import { resolve } from 'path'
import { defineConfig } from 'electron-vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import { createRequire } from 'node:module'
import { normalizePath } from 'vite'
import path from 'node:path'
import { viteStaticCopy } from 'vite-plugin-static-copy'

const require = createRequire(import.meta.url)
const pdfjsDistPath = path.dirname(require.resolve('pdfjs-dist/package.json'))
const cMapsDir = normalizePath(path.join(pdfjsDistPath, 'cmaps'))
const standardFontsDir = normalizePath(path.join(pdfjsDistPath, 'standard_fonts'))

// Pure-JS deps to bundle into out/main/index.js. Anything not listed here stays
// external and is resolved from node_modules at runtime. electron-builder's pnpm
// dep walker silently drops transitive deps on Windows, so we inline the pure-JS
// ones to remove the risk class entirely.
//
// Keep external (do NOT add here):
//   - better-sqlite3, hnswlib-node, @xenova/transformers — native bindings
//   - @sentry/electron — crashpad handler copied from node_modules by electron-builder
//   - electron-updater — reads app-update.yml via process.resourcesPath at runtime
const BUNDLE_INTO_MAIN = ['jszip', 'drizzle-orm', '@electron-toolkit/utils']

export default defineConfig({
  main: {
    build: {
      externalizeDeps: { exclude: BUNDLE_INTO_MAIN }
    }
  },
  preload: {
    build: {
      externalizeDeps: true
    }
  },
  renderer: {
    root: resolve('src/renderer'),
    resolve: {
      alias: {
        '@': resolve('src/renderer/src'),
        '@components': resolve('src/renderer/src/components')
      }
    },
    plugins: [
      tailwindcss(),
      tanstackRouter({
        target: 'react',
        autoCodeSplitting: true,
        routesDirectory: resolve('src/renderer/src/routes'),
        generatedRouteTree: resolve('src/renderer/src/routeTree.gen.ts')
      }),
      react(),
      viteStaticCopy({
        targets: [
          { src: cMapsDir, dest: '' },
          { src: standardFontsDir, dest: '' }
        ]
      })
    ],
    build: {
      rollupOptions: {
        input: resolve('src/renderer/index.html')
      }
    }
  }
})
