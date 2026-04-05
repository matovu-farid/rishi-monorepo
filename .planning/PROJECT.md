# Rishi Mobile App

## What This Is

A mobile reading app (iOS & Android) built with Expo/React Native that achieves full feature parity with the Rishi Tauri desktop app. Users can load EPUB and PDF books, read them with a polished viewer, ask AI questions about book content (RAG), listen via text-to-speech, and use speech input — all synced across desktop and mobile.

## Core Value

Users can read their books and interact with AI on their phone with the same experience they get on desktop, with everything synced between devices.

## Requirements

### Validated

- ✓ Cloudflare Worker API gateway (auth exchange, TTS proxy, LLM completions, realtime secrets) — existing
- ✓ Clerk authentication provider — existing
- ✓ Upstash Redis auth state relay — existing
- ✓ OpenAI integration (TTS, completions, realtime) via Worker — existing
- ✓ Sentry error tracking infrastructure — existing
- ✓ Expo project scaffolding with tab-based layout — existing

### Active

- [ ] EPUB book loading and rendering on mobile
- [ ] PDF book loading and rendering on mobile
- [ ] Local file import (pick EPUB/PDF from device storage)
- [ ] Cloud sync for books between desktop and mobile
- [ ] Book metadata display and library view
- [ ] Reading progress tracking and sync across devices
- [ ] Text chunking and embedding for RAG (on-device preferred, server fallback)
- [ ] Vector search for semantic retrieval on mobile
- [ ] AI Q&A about book content (RAG pipeline)
- [ ] Text-to-speech playback with queue, caching, and controls
- [ ] Speech input / voice interaction
- [ ] Mobile auth flow (Clerk React Native SDK)
- [ ] JWT-authenticated API calls to Cloudflare Worker
- [ ] Highlights and annotations with cross-device sync
- [ ] AI conversation history sync between desktop and mobile
- [ ] Local SQLite storage for books and chunk data on mobile
- [ ] Offline reading capability (books available without network)

### Out of Scope

- Desktop app changes — mobile app consumes existing Worker APIs
- Marketing website or landing page changes
- Push notifications — not in desktop parity scope
- Monetization or payment features
- Social/sharing features

## Context

The Rishi monorepo already has four apps: a Tauri desktop app (the primary product), a Next.js web app (auth landing page), a Cloudflare Worker (API gateway), and a skeleton Expo mobile app with placeholder screens.

The desktop app's core features live in Rust: EPUB/PDF parsing, local embedding via `embed_anything`, HNSW vector search, and SQLite via Diesel. These Rust capabilities don't exist on mobile, so the mobile app needs either React Native equivalents or server-side processing via the Worker.

The existing Expo app at `apps/mobile/` uses Expo Router ~6 with tab-based navigation. Whether to build on it or re-scaffold depends on research into the current setup's viability.

Auth on desktop uses a browser redirect flow (Tauri → web app → Clerk → deep link back). Mobile will likely use Clerk's React Native SDK directly, which is simpler.

Cloud sync is a new capability — the desktop app currently stores everything locally. This will require new Worker endpoints and a sync protocol for books, reading progress, highlights, and AI history.

## Constraints

- **Tech stack**: Must use Expo/React Native (already in monorepo); must integrate with existing Cloudflare Worker
- **Auth provider**: Must use Clerk (existing infrastructure)
- **API gateway**: All AI/LLM calls must go through the Cloudflare Worker (never direct from client)
- **On-device preference**: Prefer on-device processing for embeddings and vector search if feasible on mobile; fall back to server-side if research shows it's impractical
- **Monorepo**: Must live in `apps/mobile/` within the existing monorepo structure

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| On-device vs server-side processing | User prefers on-device for embeddings/vector search; research will determine feasibility | — Pending |
| Build on existing Expo app vs fresh start | Existing app is minimal (placeholder screens); decision depends on scaffold quality | — Pending |
| Sync architecture | Full cross-device sync needed for books, progress, highlights, AI history | — Pending |

---
*Last updated: 2026-04-05 after initialization*
