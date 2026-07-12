import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  resolve: {
    alias: [
      {
        find: /^@rishi\/shared\/schema$/,
        replacement: path.resolve(__dirname, "../../packages/shared/src/schema.ts"),
      },
      {
        find: /^@rishi\/shared$/,
        replacement: path.resolve(__dirname, "../../packages/shared/src"),
      },
    ],
  },
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts"],
    exclude: ["node_modules", "dist"],
  },
});
