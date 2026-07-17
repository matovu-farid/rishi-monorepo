import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "sqlite",
  driver: "durable-sqlite",
  schema: "./src/durable-objects/user-usage-ledger/schema.ts",
  out: "./drizzle/ledger-do-migrations",
});
