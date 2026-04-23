import { defineConfig } from "vite";
import type { Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { tanstackRouter } from "@tanstack/router-plugin/vite";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";
import fs from "node:fs";
import { createRequire } from "node:module";
import { normalizePath } from "vite";
import { viteStaticCopy } from "vite-plugin-static-copy";

const require = createRequire(import.meta.url);
const pdfjsDistPath = path.dirname(require.resolve("pdfjs-dist/package.json"));
const cMapsDir = normalizePath(path.join(pdfjsDistPath, "cmaps"));
const standardFontsDir = normalizePath(
  path.join(pdfjsDistPath, "standard_fonts")
);
const wasmDir = normalizePath(path.join(pdfjsDistPath, "wasm"));

const host = process.env.TAURI_DEV_HOST;

/**
 * Vite plugin that prepends polyfills to the pdfjs Web Worker after build.
 * Workers run in a separate JS context and don't inherit main-thread polyfills.
 * pdfjs-dist v5.x uses Promise.withResolvers (Safari 18.2+), URL.parse (18+),
 * Array.at (15.4+), etc. — all of which crash older WebKit without polyfills.
 */
function pdfWorkerPolyfills(): Plugin {
  return {
    name: "pdf-worker-polyfills",
    apply: "build",
    closeBundle() {
      const distDir = path.resolve(__dirname, "dist");
      const files = fs.readdirSync(distDir, { recursive: true }) as string[];
      const workerFile = files.find((f) =>
        typeof f === "string" && f.includes("pdf.worker") && f.endsWith(".mjs")
      );
      if (!workerFile) return;
      const workerPath = path.join(distDir, workerFile);
      const polyfills = `/* Worker polyfills for older WebKit */
if(typeof URL.parse!=="function"){URL.parse=function(u,b){try{return new URL(u,b)}catch{return null}};}
if(typeof Promise.withResolvers!=="function"){Promise.withResolvers=function(){let r,j;const p=new Promise((a,b)=>{r=a;j=b});return{promise:p,resolve:r,reject:j}};}
if(typeof globalThis.structuredClone!=="function"){globalThis.structuredClone=function(v){return JSON.parse(JSON.stringify(v))};}
if(typeof Object.hasOwn!=="function"){Object.hasOwn=function(o,p){return Object.prototype.hasOwnProperty.call(o,p)};}
if(typeof [].at!=="function"){Array.prototype.at=function(i){return this[i>=0?i:this.length+i]};String.prototype.at=function(i){return this[i>=0?i:this.length+i]};}
`;
      const content = fs.readFileSync(workerPath, "utf-8");
      fs.writeFileSync(workerPath, polyfills + content);
    },
  };
}

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [
    tailwindcss(),
    tanstackRouter({
      target: "react",
      autoCodeSplitting: true,
    }),
    react({
      babel: {
        plugins: [["babel-plugin-react-compiler"]],
      },
    }),
    viteStaticCopy({
      targets: [
        {
          src: cMapsDir,
          dest: "",
        },
        {
          src: standardFontsDir,
          dest: "",
        },
        {
          src: wasmDir,
          dest: "",
        },
      ],
    }),
    pdfWorkerPolyfills(),
  ],
  resolve: {
    alias: {
      "@components": "/src/components",
      "@": "/src",
      "@epubjs": "./src/epubjs/lib",
    },
  },

  // Target older WebKit/Chromium so Vite transpiles modern syntax.
  // Safari 14.1 = macOS 11 Big Sur (2020) — our minimum supported version.
  // This handles SYNTAX (optional chaining, class fields, etc.) but NOT
  // runtime APIs (URL.parse, Promise.withResolvers) — those need polyfills.ts.
  build: {
    target: ["safari14", "chrome90"] as const,
  },

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
}));
