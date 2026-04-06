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
- ✓ Mobile auth flow (Clerk Expo SDK + Worker JWT exchange) — Phase 1 complete
- ✓ JWT persistence in secure storage across restarts — Phase 1 complete
- ✓ Authenticated API client with 401 auto-refresh — Phase 1 complete
- ✓ Custom Expo dev build (not Expo Go) — Phase 1 complete
- ✓ EPUB book loading and rendering with paginated view — Phase 2 complete
- ✓ EPUB theme switching (Light/Dark/Sepia) — Phase 2 complete
- ✓ EPUB font size adjustment — Phase 2 complete
- ✓ EPUB table of contents navigation — Phase 2 complete
- ✓ Reading position persistence via ePubCFI — Phase 2 complete
- ✓ Local file import (EPUB from device storage) — Phase 2 complete
- ✓ Book library view with import flow — Phase 2 complete
- ✓ PDF book loading and rendering with native renderer — Phase 3 complete
- ✓ PDF page navigation and position persistence — Phase 3 complete
- ✓ Unified library (EPUB + PDF) with format badges — Phase 3 complete
- ✓ Book deletion with confirmation — Phase 3 complete
- ✓ Import chooser supporting both EPUB and PDF — Phase 3 complete

### Active

- ✓ Cloud sync for books between desktop and mobile — Phase 4 complete
- ✓ Reading progress tracking and sync across devices — Phase 5 complete
- ✓ Text chunking and embedding for RAG (on-device preferred, server fallback) — Phase 6 complete
- ✓ Vector search for semantic retrieval on mobile — Phase 6 complete
- ✓ AI Q&A about book content (RAG pipeline) — Phase 6 complete
- ✓ Text-to-speech playback with queue, caching, and controls — Phase 7 complete
- ✓ Speech input / voice interaction — Phase 7 complete
- [ ] Mobile auth flow (Clerk React Native SDK)
- [ ] JWT-authenticated API calls to Cloudflare Worker
- ✓ Highlights and annotations with cross-device sync — Phase 5 complete
- ✓ AI conversation history sync between desktop and mobile — Phase 6 complete
- ✓ Local SQLite storage for books and chunk data on mobile — Phase 4 complete (Drizzle ORM)
- ✓ Offline reading capability (books available without network) — Phase 4 complete
- ✓ Desktop SQLite migration to UUID sync identifiers — Phase 8 complete
- ✓ Shared TypeScript sync engine (desktop + mobile) — Phase 8 complete
- ✓ Bidirectional book/progress/highlight sync between desktop and mobile — Phase 8 complete
- ✓ Desktop epub.js highlight persistence to SQLite — Phase 8 complete
- ✓ Desktop file hashing and R2 upload on book import — Phase 8 complete
- ✓ Synced-book R2 download on chat open (getBookForReading) — Phase 9 complete
- ✓ Server-side embedding fallback when on-device model unavailable — Phase 9 complete
- ✓ Desktop multi-color highlights UI (yellow, green, blue, pink) with notes and navigation — Phase 10 complete
- ✓ Desktop reader settings (font size, font family) with persistence — Phase 10 complete
- ✓ Desktop voice input for AI chat via MediaRecorder + server transcription — Phase 10 complete
- ✓ Desktop RAG chat with source chunk references — Phase 10 complete
- ✓ Server embedding fallback integrated into desktop process_epub — Phase 10 complete
- ✓ Write-triggered sync (2s debounce) on desktop — Phase 10 complete

### Out of Scope

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
| On-device vs server-side processing | User prefers on-device; research confirms feasible via react-native-executorch + sqlite-vec | On-device with server fallback for bulk |
| Build on existing Expo app vs fresh start | Existing scaffold is solid (Expo 54, RN 0.81.5, NativeWind, New Architecture) | Build on existing |
| Sync architecture | Full cross-device sync needed for books, progress, highlights, AI history | D1 + R2 backend, LWW sync, expo-sqlite + Drizzle on mobile |
| Desktop sync integration | Research found desktop changes required for bidirectional sync | Phase 8 complete — UUID migration, shared sync engine, file sync, highlight persistence |

---
*Last updated: 2026-04-06 after Phase 10 completion — desktop feature parity achieved*
