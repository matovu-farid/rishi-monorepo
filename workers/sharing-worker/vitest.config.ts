import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          compatibilityFlags: ["nodejs_compat"],
          bindings: {
            WORKER_HMAC_SECRET: "test-secret-do-not-use-in-prod",
            AUTH_BASE_URL: "http://localhost:3000",
            // Mirrors `wrangler dev --var TEST_AUTH_ALLOWED:1` used by the
            // Playwright E2E harness — enables the `userId--DisplayName`
            // bearer shortcut. Production wrangler.jsonc deliberately omits
            // this var so the shortcut is rejected with 401.
            TEST_AUTH_ALLOWED: "1",
          },
        },
      },
    },
  },
});
