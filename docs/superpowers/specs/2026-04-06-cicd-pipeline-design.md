# CI/CD Pipeline Design — Rishi Monorepo

## Overview

Full CI/CD pipeline for the Rishi monorepo covering all four apps: desktop (Tauri), web (Next.js, already automated), mobile (Expo), and worker (Cloudflare). Uses GitHub Actions with separate workflow files per concern.

## Design Decisions

- **Approach:** One workflow file per concern (not a single monorepo workflow or Turborepo orchestration). Each app has different runtimes (Rust, Next.js, Expo, Cloudflare Worker) with no shared build graph.
- **Release strategy:** Tag-based (`v*`) for desktop and mobile releases. Push-to-main with path filtering for worker deployment.
- **PR quality gates:** Lint and test all apps on every PR regardless of which files changed. Only build artifacts for affected apps.
- **Code signing:** Apple Developer ID signing and notarization for macOS. Windows signing deferred. Linux unsigned.
- **Package manager:** Bun throughout.

## Workflow Files

### 1. `ci.yml` — Lint & Test (Every PR + Push to Main)

**Trigger:** `pull_request` and `push` to `main`.

**Jobs (parallel):**

| Job | Runner | Steps |
|-----|--------|-------|
| `lint-and-test-desktop` | `ubuntu-latest` | Install Bun, install system deps (`libwebkit2gtk-4.1-dev`, `libappindicator3-dev`, etc.), `bun install`, `bun run lint`, `bun run test` in `apps/main/` |
| `lint-and-test-web` | `ubuntu-latest` | Install Bun, `bun install`, `bun run lint`, `bun run build` in `apps/web/` |
| `lint-and-test-mobile` | `ubuntu-latest` | Install Bun, `bun install`, `bun run lint` in `apps/mobile/` (lint only — no device tests) |
| `lint-and-test-worker` | `ubuntu-latest` | Install Bun, `bun install`, lint/typecheck in `workers/worker/` |
| `check-rust` | `ubuntu-latest` | Install Rust stable, system deps, `cargo check` and `cargo clippy` in `apps/main/src-tauri/` |

### 2. `release-desktop.yml` — Tauri Desktop Release (Tag-Based)

**Trigger:** Tags matching `v*` (e.g., `v0.2.0`).

**Strategy:** Matrix build across 3 platforms using `tauri-apps/tauri-action`.

| Platform | Runner | Artifacts |
|----------|--------|-----------|
| macOS (Universal) | `macos-latest` | `.dmg`, `.app.tar.gz` + `.sig` |
| Windows | `windows-latest` | `.msi`, `.nsis` + `.sig` |
| Linux | `ubuntu-22.04` | `.deb`, `.AppImage` + `.sig` |

**Flow:**
1. Checkout code
2. Install Bun, run `bun install` in `apps/main/`
3. Install Rust stable toolchain
4. Install platform-specific system dependencies (Linux: `libwebkit2gtk-4.1-dev`, `libappindicator3-dev`, `librsvg2-dev`, `patchelf`, etc.)
5. Run `tauri-apps/tauri-action` which handles: frontend build (`bun run build`), Rust compilation, bundling, signing, and artifact upload
6. The action creates a GitHub Release from the tag with all platform artifacts attached
7. Generates and uploads `latest.json` for the in-app updater

**Apple Code Signing & Notarization:**
- The `tauri-apps/tauri-action` handles signing and notarization automatically when secrets are provided
- macOS builds are signed with Developer ID Application certificate and notarized with Apple

**Windows Code Signing:**
- Deferred. Builds produce unsigned `.msi` and `.nsis` installers.
- Can be added later by providing a Windows code signing certificate as a secret.

**Updater Integration:**
- `tauri-apps/tauri-action` generates `latest.json` with version, platform download URLs, and update signatures
- The existing updater config in `tauri.conf.json` already points to the correct endpoint: `https://github.com/matovu-farid/rishi/releases/latest/download/latest.json`
- Users running the app receive automatic update prompts

### 3. `deploy-worker.yml` — Cloudflare Worker Deployment

**Trigger:** Push to `main` when files in `workers/worker/` change (path filter).

**Flow:**
1. Checkout code
2. Install Bun, run `bun install` in `workers/worker/`
3. Run `wrangler deploy --minify`

### 4. `release-mobile.yml` — Expo Mobile Release (Tag-Based)

**Trigger:** Tags matching `v*`.

**Flow:**
1. Checkout code
2. Install Bun, run `bun install` in `apps/mobile/`
3. Run `eas build --platform all --non-interactive` to trigger builds on Expo's cloud infrastructure
4. Optionally run `eas submit` to push to App Store / Play Store

EAS Build runs on Expo's servers, so the GitHub Action just triggers and monitors it — no need for macOS runners for iOS builds.

## Architecture Diagram

```
Push/PR to main          Tag v*
    |                      |
    v                      v
+---------+    +-----------------------+
|  ci.yml |    |  release-desktop.yml  |
|         |    |  +-----+-----+-----+  |
| lint    |    |  |macOS| Win |Linux|  |
| test    |    |  +--+--+--+--+--+--+  |
| clippy  |    |     +-----+-----+     |
| (all)   |    |     GitHub Release    |
+---------+    +-----------------------+
                           |
Push to main       +------+------+
(workers/**)       |             |
    |         +----+----+  +----+----+
    v         |release- |  | latest  |
+---------+   |mobile   |  | .json   |
| deploy- |   | (EAS)   |  |(updater)|
| worker  |   +---------+  +---------+
|(wrangler)|
+---------+
```

## GitHub Secrets Required

### Apple Signing (for `release-desktop.yml`)

| Secret | Value | Source |
|--------|-------|--------|
| `APPLE_CERTIFICATE` | Base64-encoded `.p12` certificate | Export from Keychain, `base64 -i Certificates.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file | Set during export |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Farid Matovu (9VL7VRY6QZ)` | Certificate common name |
| `APPLE_ID` | `faridmato90@gmail.com` | Apple Developer account email |
| `APPLE_PASSWORD` | App-specific password | Generate at appleid.apple.com |
| `APPLE_TEAM_ID` | `9VL7VRY6QZ` | Apple Developer Team ID |

### Tauri Updater (for `release-desktop.yml`)

| Secret | Value | Source |
|--------|-------|--------|
| `TAURI_SIGNING_PRIVATE_KEY` | Updater private key | The private key matching the pubkey in `tauri.conf.json` |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Password for the private key (if set) | Set during key generation |

### Cloudflare (for `deploy-worker.yml`)

| Secret | Value | Source |
|--------|-------|--------|
| `CLOUDFLARE_API_TOKEN` | API token with Workers edit permission | Cloudflare dashboard → API Tokens |

### Expo (for `release-mobile.yml`)

| Secret | Value | Source |
|--------|-------|--------|
| `EXPO_TOKEN` | Access token | expo.dev → Account Settings → Access Tokens |

## Bundle Identifier

The Tauri app bundle identifier is `com.matovu-farid.com.rishi`, matching the Apple Developer portal App ID configuration.

## Known Issues

### Windows Build Blocked — RESOLVED 2026-04-16

**Status:** Resolved. The `webrtc-audio-processing` crate was declared in `apps/main/src-tauri/Cargo.toml` but had zero usages anywhere in the Rust source; TTS (`speach.rs`) uses a remote HTTP endpoint and needs no local audio-processing library. The crate was removed entirely, unblocking Windows builds and simplifying CI.

**Changes:**
- Removed `webrtc-audio-processing` from `apps/main/src-tauri/Cargo.toml` and regenerated `Cargo.lock` (dropped `webrtc-audio-processing-sys`, `autotools`, `fs_extra`, `prettyplease`).
- Dropped macOS `brew install libtool autoconf automake` step from `.github/workflows/release-desktop.yml`.
- Dropped the Windows MSYS2 autotools install step and the `Add MSYS2 to PATH` step from the same workflow.

**Historical context:** The original spec proposed four alternative fixes (cross-compile via cargo-xwin, conditional compilation, vendored prebuilts, replacing the crate) before the root cause — that the dependency was dead code — was identified. If echo cancellation or noise suppression becomes a real requirement on the Rust side, revisit with a platform-aware selection (the OpenAI Realtime API already provides browser-side echo cancellation via WebRTC, see `.planning/milestones/v1.0-phases/11-mobile-feature-parity/11-RESEARCH.md`).

## What This Does NOT Cover

- **Web app deployment** — already automated separately
- **Automated version bumping** — versions are bumped manually before tagging
- **Branch protection rules** — recommended but not part of this pipeline design
- **Caching strategy** — Rust compilation and Bun dependency caching will be added for performance but are implementation details
