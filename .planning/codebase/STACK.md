# Technology Stack

**Analysis Date:** 2026-04-05

## Languages

**Primary:**
- TypeScript ~5.8.3 - All frontend apps (main, web, mobile) and Cloudflare Worker
- Rust (edition 2021) - Tauri backend (`apps/main/src-tauri/`)

**Secondary:**
- CSS / Tailwind - Styling across all apps

## Runtime

**Environments:**
- Desktop (Tauri v2): Rust backend + WebView frontend, macOS/Windows/Linux
- Web (Next.js): Node.js server, deployed to Vercel
- Mobile (Expo ~54): React Native, iOS and Android
- Edge (Cloudflare Workers): V8 isolates, no Node.js runtime

**Package Manager:**
- Bun — used in `apps/main` (`bun run generate-types`, scripts)
- npm/pnpm lockfiles not confirmed; Bun is the designated runner
- Lockfile: Not confirmed in exploration (no root lockfile found)

## Frameworks

**Core:**
- Tauri v2 — Desktop app shell; bridges Rust backend to React frontend (`apps/main/src-tauri/`)
- Next.js 16.0.10 — Web authentication app (`apps/web/`)
- Expo ~54 / React Native 0.81.5 — Mobile app (`apps/mobile/`)
- Hono ^4.10.6 — Cloudflare Worker HTTP framework (`workers/worker/`)

**UI:**
- React 19.2.0 — Used across desktop and web
- Radix UI — Headless component primitives (both `apps/main` and `apps/web`)
- Tailwind CSS v4 — Desktop and web; v3 for mobile (NativeWind)
- Framer Motion ^12 — Animations in desktop app
- Lucide React — Icon library (desktop and web)

**State Management:**
- Jotai ^2.15 — Desktop (`apps/main`) and web (`apps/web`) atom-based state
- Zustand ^5 — Additional state in desktop app

**Routing:**
- TanStack Router ^1.133 — Desktop app (`apps/main`)
- Next.js App Router — Web app (`apps/web`)
- Expo Router ~6 — Mobile app (`apps/mobile`)

**Data Fetching:**
- TanStack Query ^5.90 — Desktop app

**Testing:**
- Vitest ^4.0 — Desktop app (`apps/main`); config at `apps/main/vitest.config.ts`, `apps/main/vitest.browser.config.ts`
- Playwright ^1.57 — Browser test runner for desktop
- Rust test framework (built-in `#[cfg(test)]`) + expectest 0.12, pretty_assertions, expect-test — Tauri backend

**Build/Dev:**
- Vite ^7 — Desktop app bundler (`apps/main/vite.config.ts`)
- Wrangler ^4.4 — Cloudflare Worker dev/deploy (`workers/worker/wrangler.jsonc`)
- Tauri CLI ^2 — Desktop build orchestration
- babel-plugin-react-compiler 1.0.0 — React compiler optimization on desktop

## Key Dependencies

**Critical:**
- `embed_anything` 0.6.5 (Rust) — Local text embedding for RAG pipeline; runs inference on-device
- `hnsw_rs` 0.3.3 (Rust) — In-process HNSW vector index for similarity search (`apps/main/src-tauri/src/vectordb.rs`)
- `diesel` 2.3.4 (Rust) + `diesel_migrations` — SQLite ORM with connection pooling (`apps/main/src-tauri/src/db.rs`)
- `kysely` ^0.28 + `kysely-dialect-tauri` ^1.2 — TypeScript query builder over Tauri SQL plugin
- `@openai/agents` ^0.3.4 — OpenAI Agents SDK in desktop frontend
- `openai` ^6.9 — OpenAI SDK in Cloudflare Worker
- `@clerk/nextjs` ^6.36 — Auth in web app
- `@clerk/backend` ^2.29 — Auth in Cloudflare Worker
- `@upstash/redis` ^1.36 — Redis client used in both web and worker for auth state relay

**Infrastructure:**
- `tauri-plugin-sql` ~2 (SQLite feature) — TypeScript SQL access from Tauri frontend
- `tauri-plugin-store` ~2 — Key-value persistent store (used for JWT and auth state)
- `tauri-plugin-deep-link` ~2 — OAuth callback via `rishi://` custom URL scheme
- `tauri-plugin-sentry` 0.5 + `sentry` 0.42 (Rust) — Crash reporting in Tauri app
- `@sentry/nextjs` ^10 — Error tracking in Next.js
- `@sentry/cloudflare` ^10.32 — Error tracking in Cloudflare Worker
- `@vercel/analytics` 1.3.1 — Analytics in web app
- `r2d2` 0.8 (Rust) — SQLite connection pool (max 10 connections, min 2 idle)
- `epub` 2.1.5 + `epubjs` ^0.3.93 — EPUB parsing (Rust + JS)
- `react-pdf` ^10.2 + `pdf` 0.9.0 (Rust) — PDF rendering and parsing
- `@react-pdf/renderer` ^4.3 — PDF generation (desktop)
- `cpal` 0.16 + `wav_io` 0.1 + `tauri-plugin-mic-recorder` 2 — Audio capture for speech features

## Configuration

**Environment:**
- Desktop (`apps/main`): Uses Tauri plugin store (`store.json`) for user tokens; build env `SENTRY_DSN` optional
- Web (`apps/web`): Clerk and Upstash Redis credentials via environment variables (no `.env` files detected in repo)
- Worker (`workers/worker`): Cloudflare Worker bindings — `DEEPGRAM_KEY`, `OPENAI_API_KEY`, `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`, `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`, `JWT_SECRET`
- Worker config: `workers/worker/wrangler.jsonc`

**Build:**
- Desktop: `apps/main/vite.config.ts` (Vite 7), `apps/main/src-tauri/Cargo.toml`
- Web: `apps/web/next.config.ts` (Next.js with Sentry wrapper)
- Mobile: `apps/mobile/metro.config.js`, `apps/mobile/babel.config.js`
- Type generation: `cargo tauri-typegen generate` outputs to `apps/main/src/generated/`

## Platform Requirements

**Development:**
- Rust toolchain (edition 2021) required for desktop app
- Bun runtime for desktop frontend scripts
- Wrangler for Worker development
- Expo CLI for mobile

**Production:**
- Desktop: Tauri-packaged native binary with SQLite file at OS app data dir
- Web: Vercel (inferred from `@vercel/analytics` and Sentry Vercel cron monitor config)
- Worker: Cloudflare Workers (edge runtime, `compatibility_date: 2025-11-17`)
- Mobile: iOS App Store / Google Play via Expo EAS

---

*Stack analysis: 2026-04-05*
