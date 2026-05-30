# rishi-sharing-worker

Cloudflare Worker + Durable Object backend for shared reading sessions in the Rishi Electron app.

See `docs/superpowers/specs/2026-05-30-shared-reading-electron-design.md` for the full design.

## Local dev

    pnpm install
    pnpm dev
    pnpm test

## Secrets

Generate a 48-byte secret and set it for the production environment:

    openssl rand -base64 48 | pnpm exec wrangler secret put WORKER_HMAC_SECRET --env production

## Deploy

    pnpm exec wrangler login                                 # one-time, interactive
    pnpm exec wrangler deploy --env production --minify

The output prints the workers.dev URL (e.g. `https://rishi-sharing-worker.<account>.workers.dev`).

## Smoke check

    curl -i https://rishi-sharing-worker.<account>.workers.dev/health
    # Expected: HTTP/2 200, body: ok

## Tail logs

    pnpm exec wrangler tail --env production

