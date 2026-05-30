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
          },
        },
      },
    },
  },
});
