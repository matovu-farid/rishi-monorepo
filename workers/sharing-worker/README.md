# rishi-sharing-worker

Cloudflare Worker + Durable Object backend for shared reading sessions in the Rishi Electron app.

See `docs/superpowers/specs/2026-05-30-shared-reading-electron-design.md` for the full design.

## Local dev

    pnpm install
    pnpm dev
    pnpm test

## Secrets

    wrangler secret put WORKER_HMAC_SECRET    # 32+ random bytes, base64

## Deploy

    pnpm deploy
