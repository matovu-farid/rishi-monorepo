// `drizzle-kit generate --config=drizzle-do.config.ts` (Task 4) emits a
// plain-JS `migrations.js` bundle — see drizzle-orm's durable-sqlite driver
// docs. tsconfig.json does not set `allowJs`, so this ambient declaration
// lets `ledger.ts` import it with a real type instead of failing to
// resolve.
//
// A `declare module` using the exact relative specifier from `ledger.ts`
// (e.g. `"../../../drizzle/ledger-do-migrations/migrations"`) does NOT
// work here — verified against the installed TypeScript 5.8.3 with this
// project's `moduleResolution: "Bundler"` + no `allowJs`: TypeScript only
// matches relative ambient module specifiers when they resolve from the
// *declaring* file to the exact same path as a real, existing file (which
// `migrations.js` — a `.js`, not `.d.ts`/`.ts` — does not satisfy). A
// wildcard ambient module pattern is TypeScript's supported mechanism for
// this exact case (untyped generated `.js` imported from a `.ts` module);
// scoped to the `ledger-do-migrations/migrations` suffix so it can't
// accidentally shadow an unrelated module.
declare module "*/ledger-do-migrations/migrations" {
  const migrations: { migrations: Record<string, string> };
  export default migrations;
}
