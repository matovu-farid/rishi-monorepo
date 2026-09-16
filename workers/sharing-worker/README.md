# Rishi sharing Worker

This Cloudflare Worker and its `SessionRoom` Durable Object preserve the
checked-in shared-reading transport used by released legacy clients. The
deprecated Electron source is archived in the private
[`rishi-electron-legacy`](https://github.com/matovu-farid/rishi-electron-legacy/tree/e460dda4eed5d69134d2e7f865b2d14a51de277e)
repository.

## Current compatibility boundary

The runtime on `origin/main` exposes `/health` and the frozen legacy `/v1`
session, redeem, user-search, and WebSocket routes. Its Wrangler configuration
contains only the `SESSION_ROOM` binding, the `SessionRoom` class, and the `v1`
migration.

Apple `/v2` sharing is planned but is not implemented on `origin/main`. Do not
point the Apple app at `/v1` or claim Apple shared-reading acceptance has been
tested against `/v2`. Implement `/v2` separately with its own Durable Object
class, binding, and append-only migration before Apple testing. Preserve `/v1`
unchanged for released-client compatibility.

## Local checks

Use Bun for this Worker, as required by repository policy:

```bash
cd workers/sharing-worker
bun install
bun run test
bun run dev
```

The local health check is:

```bash
curl -i http://localhost:8787/health
```

## Secrets and deployment

`WORKER_HMAC_SECRET` signs join and reconnect tokens. It is the same trust
secret named `SHARING_INTERNAL_SECRET` by the primary Worker; never rotate or
configure only one side.

```bash
openssl rand -base64 48 | bunx wrangler secret put WORKER_HMAC_SECRET --env production
bunx wrangler tail --env production
```

Do not deploy from a feature branch until the mandatory comparison with
`origin/main` proves every released API, binding, migration, and Durable Object
contract remains backward compatible. Record that audit, confirm both Workers'
shared secret configuration, and obtain deployment authorization before using:

```bash
bunx wrangler deploy --env production --minify
```
