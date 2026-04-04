import { defineConfig } from "vitest/config";
import { playwright } from "@vitest/browser-playwright";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [
    react(),
    nodePolyfills({
      include: ["fs", "url", "path"],
    }),
  ],

  resolve: {
    alias: {
      "@components": "/src/components",
      "@": "/src",
      "@epubjs": "./src/epubjs/lib",
    },
  },
  test: {
    globals: true,
    // Only include browser test files
    include: ["**/*.browser.test.{ts,tsx}"],
    browser: {
      enabled: true,
      provider: playwright(),
      // https://vitest.dev/guide/browser/playwright
      instances: [{ browser: "chromium" }],
    },
  },
});
