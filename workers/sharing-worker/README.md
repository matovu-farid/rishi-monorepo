# Rishi sharing Worker

This Cloudflare Worker preserves the frozen `/v1` `SessionRoom` transport used
by released legacy clients. The deprecated Electron source is archived in the
private
[`rishi-electron-legacy`](https://github.com/matovu-farid/rishi-electron-legacy/tree/e460dda4eed5d69134d2e7f865b2d14a51de277e)
repository.

The Apple shared-reading feature adds a separate `/v2` transport backed by the
`AppleSessionRoom` Durable Object, binding, and append-only migration. Never add
Apple semantics to `/v1`, and do not claim production acceptance until the
versioned rollout and two-account MCP evidence gates pass.

## Local checks

Use Bun for this Worker, as required by repository policy:

```bash
cd workers/sharing-worker
bun install
bun run test
bun run dev:local
```

For Apple development, use the repository-root launcher. It starts this Worker
together with the primary Worker, verifies both health endpoints, and stops only
the processes it owns:

```bash
scripts/start-rishi-workers-dev.sh
```

The local health check is:

```bash
curl -i http://localhost:8788/health
```

## Secrets and deployment

`WORKER_HMAC_SECRET` is the same trust secret named
`SHARING_INTERNAL_SECRET` by the primary Worker. Never configure or rotate only
one side.

Do not deploy from a feature branch. First complete the mandatory comparison
with `origin/main`, prove every released API, binding, migration, and Durable
Object contract remains backward compatible, verify both secret fingerprints,
and obtain separate deployment authorization.
