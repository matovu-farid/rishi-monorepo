// import { defineConfig } from "vitest/config";

// export default defineConfig({
//   test: {
//     globals: true,
//     // Exclude browser test files from regular test runs
//     exclude: [
//       "**/*.browser.test.{ts,tsx}",
//       "**/epubwrapper.test.tsx",
//       "node_modules/**",
//     ],
//     // ... other test config
//   },
// });

import { defineConfig } from "vitest/config";
import { playwright } from "@vitest/browser-playwright";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],

  resolve: {
    alias: {
      "@components": "/src/components",
      "@": "/src",
      "@epubjs": "./src/epubjs/lib",
    },
  },
  test: {
    globals: true,
    // Exclude browser test files from regular test runs
    exclude: [
      "**/*.browser.test.{ts,tsx}",
      "**/epubwrapper.test.tsx",
      "node_modules/**",
    ],
    browser: {
      enabled: false,
      provider: playwright(),
      // https://vitest.dev/guide/browser/playwright
      instances: [{ browser: "chromium" }],
    },
  },
});
