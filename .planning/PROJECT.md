# Rishi Mobile App

## What This Is

A cross-platform reading app (iOS, Android, macOS, Windows, Linux) with full desktop-mobile feature parity. Users can load EPUB and PDF books, read them with a polished viewer, ask AI questions about book content via on-device RAG, listen via text-to-speech, have live voice conversations with AI, and sync everything across devices.

## Core Value

Users can read their books and interact with AI on any device with the same experience, with everything synced seamlessly between desktop and mobile.

## Current State

**Shipped:** v1.1 (2026-04-07)
**Stack:** Expo/React Native (mobile), Tauri/Rust (desktop), Cloudflare Worker (API), D1/R2 (sync backend)
**Platforms:** iOS, Android, macOS, Linux, Windows

## Requirements

### Validated

- ✓ Mobile auth flow (Clerk Expo SDK + Worker JWT exchange) — v1.0
- ✓ JWT persistence in secure storage across restarts — v1.0
- ✓ Authenticated API client with 401 auto-refresh — v1.0
- ✓ Custom Expo dev build (not Expo Go) — v1.0
- ✓ EPUB rendering with paginated view, themes, font controls, TOC — v1.0
- ✓ PDF rendering with page navigation and position persistence — v1.0
- ✓ Unified library (EPUB + PDF) with import, deletion, and metadata — v1.0
- ✓ Offline-first cloud sync via D1/R2 with LWW conflict resolution — v1.0
- ✓ Book file deduplication by content hash — v1.0
- ✓ On-demand R2 download for synced books — v1.0
- ✓ Text highlights with notes, multi-color support, and cross-device sync — v1.0
- ✓ Reading progress sync across devices (ePubCFI/page number) — v1.0
- ✓ On-device RAG: ExecuTorch embeddings, sqlite-vec vector search — v1.0
- ✓ AI Q&A about book content with source passage references — v1.0
- ✓ Server-side embedding fallback when on-device model unavailable — v1.0
- ✓ AI conversation history sync (append-only merge) — v1.0
- ✓ TTS playback with queue, caching, and play/pause/stop controls — v1.0
- ✓ Voice input via speech transcription (Deepgram STT) — v1.0
- ✓ Bidirectional desktop-mobile sync with shared TypeScript engine — v1.0
- ✓ Desktop UUID migration and highlight persistence — v1.0
- ✓ Desktop highlights UI (multi-color, notes, navigation) — v1.0
- ✓ Desktop reader settings (font size, font family) with persistence — v1.0
- ✓ Desktop voice input and RAG chat with source refs — v1.0
- ✓ Write-triggered sync (2s debounce) — v1.0
- ✓ OpenAI Realtime voice chat on mobile (WebRTC) — v1.0
- ✓ AI guardrails/tripwire system — v1.0
- ✓ Sync status indicator UI — v1.0
- ✓ Sentry error tracking on mobile — v1.0
- ✓ PDF thumbnail navigation (desktop sidebar + mobile modal) — v1.1

### Active

(None — fresh for next milestone)

### Out of Scope
- Push notifications — not in current scope
- Monetization or payment features
- Social/sharing features
- Book store / purchasing
- OPDS catalog support

## Context

Shipped v1.0 across 11 phases and 31 plans in 3 days. v1.1 added PDF thumbnail navigation (1 phase, 2 plans) on the same day. The monorepo has four active apps: Tauri desktop (`apps/main`), Expo mobile (`apps/mobile`), Next.js web (`apps/web`), and Cloudflare Worker (`workers/worker`). Shared sync schema lives in `packages/shared`.

Desktop Rust backend handles EPUB/PDF parsing, local embeddings via `embed_anything`, HNSW vector search, and SQLite via Diesel. Mobile uses React Native equivalents (ExecuTorch, sqlite-vec) with server fallback.

No known gaps remain from v1.0 or v1.1.

## Constraints

- **Tech stack**: Expo/React Native (mobile), Tauri/Rust (desktop), Cloudflare Worker (API)
- **Auth provider**: Clerk (existing infrastructure)
- **API gateway**: All AI/LLM calls go through Cloudflare Worker (never direct from client)
- **On-device preference**: On-device processing for embeddings/vector search with server fallback
- **Monorepo**: Mobile at `apps/mobile/`, desktop at `apps/main/`, shared at `packages/shared/`

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| On-device embeddings with server fallback | User prefers on-device; ExecuTorch + sqlite-vec feasible | ✓ Good — works on iOS/Android, fallback covers model-not-downloaded |
| Build on existing Expo scaffold | Expo 54, RN 0.81.5, NativeWind, New Architecture already solid | ✓ Good — no re-scaffold needed |
| D1 + R2 sync with LWW | Offline-first with simple conflict resolution | ✓ Good — works across desktop and mobile |
| Desktop sync as late phase | Mobile standalone first, desktop integration Phase 8 | ✓ Good — allowed focused mobile development |
| Shared TypeScript sync engine | Same push/pull logic for desktop and mobile | ✓ Good — reduced duplication |
| WebRTC for mobile realtime voice | @openai/agents has no RN support; raw WebRTC works | ✓ Good — direct control over connection lifecycle |
| Fail-open AI guardrails | Server-side classification, errors don't block user | ✓ Good — safety without degraded UX |
| react-pdf Thumbnail + useVirtualizer for desktop thumbnails | Reuse existing libraries, avoid new dependencies | ✓ Good — virtualized, no double PDF load |
| react-native-pdf-thumbnail for mobile | Only viable Expo-compatible native thumbnail library | ✓ Good — lazy generation, small footprint |

---
*Last updated: 2026-04-07 after v1.1 milestone completion*
