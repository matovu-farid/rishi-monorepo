import { resolve } from "path";
import { defineConfig } from "electron-vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { tanstackRouter } from "@tanstack/router-plugin/vite";
import { createRequire } from "node:module";
import { normalizePath } from "vite";
import path from "node:path";
import { viteStaticCopy } from "vite-plugin-static-copy";

const require = createRequire(import.meta.url);
const pdfjsDistPath = path.dirname(require.resolve("pdfjs-dist/package.json"));
const cMapsDir = normalizePath(path.join(pdfjsDistPath, "cmaps"));
const standardFontsDir = normalizePath(
  path.join(pdfjsDistPath, "standard_fonts")
);

export default defineConfig({
  main: {
    build: {
      rollupOptions: {
        external: ["better-sqlite3", "hnswlib-node", "epubjs"],
      },
    },
  },
  preload: {},
  renderer: {
    root: resolve("src/renderer"),
    resolve: {
      alias: {
        "@": resolve("src/renderer/src"),
        "@components": resolve("src/renderer/src/components"),
      },
    },
    plugins: [
      tailwindcss(),
      tanstackRouter({
        target: "react",
        autoCodeSplitting: true,
        routesDirectory: resolve("src/renderer/src/routes"),
        generatedRouteTree: resolve("src/renderer/src/routeTree.gen.ts"),
      }),
      react(),
      viteStaticCopy({
        targets: [
          { src: cMapsDir, dest: "" },
          { src: standardFontsDir, dest: "" },
        ],
      }),
    ],
    build: {
      rollupOptions: {
        input: resolve("src/renderer/index.html"),
      },
    },
  },
});
