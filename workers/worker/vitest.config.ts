import { defineConfig } from "vitest/config";
import path from "node:path";
import { readFileSync } from "node:fs";

export default defineConfig({
  plugins: [
    {
      name: "worker-raw-sql",
      enforce: "pre",
      transform(_code, id) {
        if (!id.endsWith(".sql")) return undefined;
        return {
          code: `export default ${JSON.stringify(readFileSync(id, "utf8"))}`,
          map: null,
        };
      },
    },
  ],
  resolve: {
    alias: [
      {
        // Legacy test mocks still use this specifier; resolve it to the
        // canonical Worker-owned Drizzle schema, never the deleted shared copy.
        find: /^@rishi\/shared\/schema$/,
        replacement: path.resolve(__dirname, "src/db/schema.ts"),
      },
      {
        find: /^@rishi\/shared$/,
        replacement: path.resolve(__dirname, "../../packages/shared/src"),
      },
      {
        find: /^cloudflare:workers$/,
        replacement: path.resolve(
          __dirname,
          "src/test-utils/cloudflare-workers.ts",
        ),
      },
    ],
  },
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts", "scripts/**/*.test.ts"],
    exclude: ["node_modules", "dist"],
  },
});
