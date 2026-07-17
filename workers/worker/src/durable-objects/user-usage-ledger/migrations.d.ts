// `drizzle-kit generate --config=drizzle-do.config.ts` (Task 4) emits a
// plain-JS `migrations.js` bundle — see drizzle-orm's durable-sqlite driver
// docs. tsconfig.json does not set `allowJs`, so this ambient declaration
// lets `ledger.ts` import it with a real type instead of failing to
// resolve. The relative specifier must match the import in `ledger.ts`
// exactly, since TypeScript resolves relative ambient module paths
// relative to the file that declares them (this file).
declare module "../../../drizzle/ledger-do-migrations/migrations" {
  const migrations: { migrations: Record<string, string> };
  export default migrations;
}
