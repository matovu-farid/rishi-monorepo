```txt
bun install
bun run dev:local
```

For Apple development, start both the primary and shared-reading Workers from
the repository root so their local service binding and health checks are wired
together:

```txt
scripts/start-rishi-workers-dev.sh
```

The local configuration uses simulated D1/R2/KV/Durable Object bindings and
must not be replaced with the production Wrangler configuration. Use the
managed launcher for Apple tests so the app receives the correct local
endpoint.

```txt
bun run deploy
```

[For generating/synchronizing types based on your Worker configuration run](https://developers.cloudflare.com/workers/wrangler/commands/#types):

```txt
bun run generate-types
```

Pass the `CloudflareBindings` as generics when instantiation `Hono`:

```ts
// src/index.ts
const app = new Hono<{ Bindings: CloudflareBindings }>()
```
