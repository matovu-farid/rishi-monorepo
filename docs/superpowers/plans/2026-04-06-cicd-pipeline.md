# CI/CD Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up GitHub Actions CI/CD for the entire Rishi monorepo — lint/test on PRs, tag-based desktop releases with Apple signing, worker deployment on push, and mobile EAS builds on tags.

**Architecture:** Four separate workflow files under `.github/workflows/`, one per concern. The CI workflow runs all linters/tests on every PR. Release workflows trigger on `v*` tags. Worker deploy triggers on push to main with path filtering.

**Tech Stack:** GitHub Actions, tauri-apps/tauri-action@v1, Bun, Rust stable, Wrangler CLI, EAS CLI

---

## File Structure

```
.github/
  workflows/
    ci.yml                  — Lint & test all apps on PR + push to main
    release-desktop.yml     — Build Tauri for macOS/Windows/Linux on v* tags
    deploy-worker.yml       — Deploy Cloudflare Worker on push to main
    release-mobile.yml      — Trigger EAS Build on v* tags
```

---

### Task 1: CI Workflow — Lint & Test All Apps

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the CI workflow file**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint-and-test-desktop:
    name: Desktop (lint + test)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/main
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install frontend dependencies
        run: bun install

      - name: Lint
        run: bun run lint

      - name: Test
        run: bun run test -- --run

  check-rust:
    name: Rust (check + clippy)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/main/src-tauri
    steps:
      - uses: actions/checkout@v4

      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy

      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf

      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: apps/main/src-tauri

      - name: Cargo check
        run: cargo check

      - name: Cargo clippy
        run: cargo clippy -- -D warnings

  lint-web:
    name: Web (lint + build)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/web
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install dependencies
        run: bun install

      - name: Lint
        run: bun run lint

      - name: Build
        run: bun run build

  lint-mobile:
    name: Mobile (lint)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/mobile
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install dependencies
        run: bun install

      - name: Lint
        run: bun run lint

  typecheck-worker:
    name: Worker (typecheck)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: workers/worker
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install dependencies
        run: bun install

      - name: Install shared package dependencies
        run: cd ../../packages/shared && bun install

      - name: Typecheck
        run: bunx tsc --noEmit
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

Run: `cd /Users/faridmatovu/projects/rishi-monorepo && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add lint and test workflow for all apps"
```

---

### Task 2: Desktop Release Workflow — Tauri Builds with Apple Signing

**Files:**
- Create: `.github/workflows/release-desktop.yml`

**Required GitHub Secrets (must be set before first tag push):**
- `APPLE_CERTIFICATE` — base64-encoded .p12
- `APPLE_CERTIFICATE_PASSWORD` — p12 password
- `APPLE_SIGNING_IDENTITY` — `Developer ID Application: Farid Matovu (9VL7VRY6QZ)`
- `APPLE_ID` — `faridmato90@gmail.com`
- `APPLE_PASSWORD` — app-specific password from appleid.apple.com
- `APPLE_TEAM_ID` — `9VL7VRY6QZ`
- `TAURI_SIGNING_PRIVATE_KEY` — content of `~/.tauri/rishi.key`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` — empty string

- [ ] **Step 1: Create the release-desktop workflow file**

```yaml
name: Release Desktop

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    name: Build & Release (${{ matrix.platform }})
    permissions:
      contents: write
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: macos-latest
            args: '--target universal-apple-darwin'
            rust_targets: 'aarch64-apple-darwin,x86_64-apple-darwin'
          - platform: ubuntu-22.04
            args: ''
            rust_targets: ''
          - platform: windows-latest
            args: ''
            rust_targets: ''

    runs-on: ${{ matrix.platform }}
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install Rust stable
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.rust_targets }}

      - uses: Swatinem/rust-cache@v2
        with:
          workspaces: apps/main/src-tauri

      - name: Install system dependencies (Linux)
        if: matrix.platform == 'ubuntu-22.04'
        run: |
          sudo apt-get update
          sudo apt-get install -y libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf

      - name: Import Apple Developer Certificate
        if: matrix.platform == 'macos-latest'
        env:
          APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
        run: |
          echo $APPLE_CERTIFICATE | base64 --decode > certificate.p12
          KEYCHAIN_PASSWORD=$(openssl rand -base64 32)
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security set-keychain-settings -t 3600 -u build.keychain
          security import certificate.p12 -k build.keychain -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" build.keychain
          security find-identity -v -p codesigning build.keychain
          rm certificate.p12

      - name: Install frontend dependencies
        run: cd apps/main && bun install

      - name: Build and release
        uses: tauri-apps/tauri-action@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_PASSWORD: ${{ secrets.APPLE_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
          TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
          TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
        with:
          projectPath: apps/main
          tagName: ${{ github.ref_name }}
          releaseName: 'Rishi ${{ github.ref_name }}'
          releaseBody: 'See the assets below to download and install.'
          releaseDraft: false
          prerelease: false
          args: ${{ matrix.args }}
          uploadUpdaterJson: true
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

Run: `cd /Users/faridmatovu/projects/rishi-monorepo && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-desktop.yml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-desktop.yml
git commit -m "ci: add desktop release workflow with Apple signing"
```

---

### Task 3: Worker Deployment Workflow

**Files:**
- Create: `.github/workflows/deploy-worker.yml`

**Required GitHub Secret:**
- `CLOUDFLARE_API_TOKEN` — API token with Workers edit permission

- [ ] **Step 1: Create the deploy-worker workflow file**

```yaml
name: Deploy Worker

on:
  push:
    branches: [main]
    paths:
      - 'workers/worker/**'
      - 'packages/shared/**'

concurrency:
  group: deploy-worker
  cancel-in-progress: true

jobs:
  deploy:
    name: Deploy to Cloudflare
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: workers/worker
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install shared package dependencies
        run: cd ../../packages/shared && bun install

      - name: Install dependencies
        run: bun install

      - name: Typecheck
        run: bunx tsc --noEmit

      - name: Deploy
        run: bunx wrangler deploy --minify
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

Run: `cd /Users/faridmatovu/projects/rishi-monorepo && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy-worker.yml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-worker.yml
git commit -m "ci: add worker deployment workflow"
```

---

### Task 4: Mobile Release Workflow

**Files:**
- Create: `.github/workflows/release-mobile.yml`

**Required GitHub Secret:**
- `EXPO_TOKEN` — from expo.dev Account Settings → Access Tokens

- [ ] **Step 1: Create the release-mobile workflow file**

```yaml
name: Release Mobile

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    name: EAS Build (iOS + Android)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/mobile
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2

      - name: Install shared package dependencies
        run: cd ../../packages/shared && bun install

      - name: Install dependencies
        run: bun install

      - name: Setup EAS
        uses: expo/expo-github-action@v8
        with:
          eas-version: latest
          token: ${{ secrets.EXPO_TOKEN }}

      - name: Lint
        run: bun run lint

      - name: Build
        run: eas build --platform all --non-interactive --no-wait
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

Run: `cd /Users/faridmatovu/projects/rishi-monorepo && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-mobile.yml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-mobile.yml
git commit -m "ci: add mobile EAS build workflow"
```

---

### Task 5: Verify All Workflows and Final Commit

**Files:**
- Verify: `.github/workflows/ci.yml`
- Verify: `.github/workflows/release-desktop.yml`
- Verify: `.github/workflows/deploy-worker.yml`
- Verify: `.github/workflows/release-mobile.yml`

- [ ] **Step 1: Validate all YAML files parse correctly**

Run:
```bash
cd /Users/faridmatovu/projects/rishi-monorepo
python3 -c "
import yaml, glob
for f in glob.glob('.github/workflows/*.yml'):
    yaml.safe_load(open(f))
    print(f'{f}: valid')
"
```
Expected:
```
.github/workflows/ci.yml: valid
.github/workflows/release-desktop.yml: valid
.github/workflows/deploy-worker.yml: valid
.github/workflows/release-mobile.yml: valid
```

- [ ] **Step 2: List all workflow files to confirm structure**

Run: `ls -la .github/workflows/`
Expected: Four `.yml` files

- [ ] **Step 3: Dry-run push check — verify git status is clean**

Run: `git status`
Expected: All workflow files committed, working tree clean

---

## GitHub Secrets Checklist

Before pushing the first `v*` tag, add these secrets at **repo → Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Required For | Status |
|--------|-------------|--------|
| `APPLE_CERTIFICATE` | release-desktop | You have the .p12 — run `base64 -i Certificates.p12 \| pbcopy` |
| `APPLE_CERTIFICATE_PASSWORD` | release-desktop | You know it |
| `APPLE_SIGNING_IDENTITY` | release-desktop | `Developer ID Application: Farid Matovu (9VL7VRY6QZ)` |
| `APPLE_ID` | release-desktop | `faridmato90@gmail.com` |
| `APPLE_PASSWORD` | release-desktop | Generate app-specific password at appleid.apple.com |
| `APPLE_TEAM_ID` | release-desktop | `9VL7VRY6QZ` |
| `TAURI_SIGNING_PRIVATE_KEY` | release-desktop | Content of `~/.tauri/rishi.key` |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | release-desktop | Empty string |
| `CLOUDFLARE_API_TOKEN` | deploy-worker | Cloudflare dashboard → API Tokens |
| `EXPO_TOKEN` | release-mobile | expo.dev → Account Settings → Access Tokens |

## How to Use

**On every PR:** CI runs automatically — lint, test, clippy for all apps.

**To release desktop + mobile:**
```bash
# Bump version in apps/main/src-tauri/tauri.conf.json and apps/mobile/app.json
git tag v0.2.0
git push origin v0.2.0
```

**Worker deploys automatically** when you push changes to `workers/worker/` or `packages/shared/` on main.
