# Web Download CTA — Design Spec

**Date:** 2026-04-16
**Scope:** `apps/web` (Next.js marketing site).
**Goal:** Turn the three inert "Download" CTAs into working download buttons that auto-detect the user's OS, default to the right binary from the latest GitHub release, and let users pick another platform or installer format via a split-button dropdown.

## 1. Goals

1. Users land on the site, see a prominent "Download for <their-OS>" CTA, click once, and get the correct installer for the latest release.
2. Users who want a different OS or installer format can open a dropdown and pick it — in one additional click.
3. The site never hardcodes a version — whatever is newest on GitHub is what gets served.
4. Mobile visitors see a graceful "Mobile coming soon" message while still being able to pick a desktop platform.
5. If GitHub is unreachable, CTAs still work (fall back to the GitHub releases page).

Non-goals: analytics dashboards, per-region mirrors, signed-checksum UI, release notes rendering on the marketing site.

## 2. Context — what already exists

- **Web app:** Next.js 16 at `apps/web`. Marketing page composes three relevant components:
  - `apps/web/src/components/hero.tsx` — "Get Started" / "Watch Demo" buttons (inert).
  - `apps/web/src/components/cta.tsx` — "Download Now" / "Learn More" buttons (inert). Has a small "Available for Mac, Windows, and Linux" caption.
  - `apps/web/src/components/header.tsx` — "Download App" buttons in desktop nav (`header.tsx:32`) and mobile menu (`header.tsx:56`), both inert.
- **Desktop app:** Tauri app in `apps/main`, current version `1.1.1`.
- **Releases:** GitHub repo `matovu-farid/rishi-monorepo`. Latest release `v1.1.1` ships the following relevant assets (non-`.sig`, non-`latest.json`, non-`.app.tar.gz`):
  | OS | Filename pattern | Format |
  |---|---|---|
  | macOS | `rishi_<ver>_universal.dmg` | `.dmg` (universal, only option) |
  | Windows | `rishi_<ver>_x64-setup.exe` | `.exe` (NSIS installer) |
  | Windows | `rishi_<ver>_x64_en-US.msi` | `.msi` (MSI installer) |
  | Linux | `rishi_<ver>_amd64.AppImage` | `.AppImage` |
  | Linux | `rishi_<ver>_amd64.deb` | `.deb` |
  | Linux | `rishi-<ver>-1.x86_64.rpm` | `.rpm` |
- **UI primitives available:** `@radix-ui/react-dropdown-menu` is already in `apps/web/package.json`, and `components/ui/` is set up for shadcn-style components. `lucide-react` supplies icons. Tailwind 4 is configured.

## 3. User-facing behavior

### 3.1 Button placements

All three of these become split-button download CTAs, sharing a single component with a `variant` prop:

| Placement | Variant | Notes |
|---|---|---|
| `hero.tsx` — replaces "Get Started" | `primary` | Keep "Watch Demo" unchanged as the secondary CTA. |
| `cta.tsx` — replaces "Download Now" | `primary` | Keep "Learn More" unchanged. Keep the "Available for Mac, Windows, and Linux" caption as reassurance. |
| `header.tsx` — replaces both instances of "Download App" | `header` | Smaller pill size to match existing nav. |

### 3.2 Primary button label & icon

- Desktop OS detected: `⬇ Download for macOS` / `⬇ Download for Windows` / `⬇ Download for Linux`.
- Mobile/unknown detected: `⬇ Download for Desktop`, with small helper text directly beneath the button: *Mobile coming soon*.
- `primary` variant: filled accent color, large.
- `header` variant: rounded pill, smaller, no helper text (even on mobile — it's the CTA section's job).

Clicking the **label portion** navigates to `/api/download/<detected-os>` (with no `?format=`, so the recommended format is used).

### 3.3 Split-button chevron & dropdown

The split button has a chevron on its right edge. Clicking it (or pressing the button's associated keyboard shortcut) opens a dropdown with platform choices. Radix `DropdownMenu` handles focus-trapping and keyboard navigation.

Dropdown contents, top to bottom:

```
Platform
  ⬇ macOS (.dmg)                      ← highlighted if detected
  ⬇ Windows (.exe)           ⌄        ← expand caret
      ↳ MSI installer (.msi)
  ⬇ Linux (.AppImage)        ⌄        ← expand caret
      ↳ Debian package (.deb)
      ↳ Fedora / RHEL (.rpm)
  ─────────────────────────────
  See all releases on GitHub ↗
```

Rules:
- Each top-level row is a link to `/api/download/<os>` (recommended format).
- The expand caret toggles visibility of alternate-format rows for that OS (accordion-style inside the dropdown). Alternate rows link to `/api/download/<os>?format=<fmt>`.
- macOS has no alternates, so no caret.
- The detected OS row is visually highlighted (subtle accent background) but not pre-expanded.
- "See all releases on GitHub" link to `https://github.com/matovu-farid/rishi-monorepo/releases/latest` opens in a new tab.

### 3.4 Mobile treatment

- If `detectOs()` returns `'mobile'` (or `'unknown'`), the `primary` variant shows `⬇ Download for Desktop` + *Mobile coming soon* caption. The label's click target is `/api/download/mac` (macOS is the most common desktop among mobile-originating visitors). The dropdown works normally.
- The `header` variant still renders a compact button without the caption, with the same `/api/download/mac` click target on mobile.

### 3.5 Error-path UX

- If release fetch fails and there is no cache: primary button label becomes `⬇ Download from GitHub`, link goes to `https://github.com/matovu-farid/rishi-monorepo/releases/latest`. Dropdown collapses to a single "Open GitHub Releases" item.
- If the user clicks a download link and the redirect endpoint can't resolve an asset (GitHub down mid-click), the endpoint 302s to the GitHub releases page.

## 4. Architecture

```
apps/web/src/
├── lib/
│   ├── releases.ts               # GitHub fetch + parse + cache (server-only)
│   └── detect-os.ts              # OS detection from request headers / UA
├── app/api/
│   ├── latest-release/route.ts   # GET → JSON of parsed release
│   └── download/[os]/route.ts    # GET → 302 to asset URL (supports ?format=)
└── components/
    ├── download-button.tsx        # Client: split button + dropdown UI
    └── download-button-server.tsx # Server wrapper: calls getLatestRelease() + detectOs()
```

### 4.1 `lib/releases.ts`

```ts
export type Os = 'mac' | 'windows' | 'linux'
export type AssetFormat = 'dmg' | 'exe' | 'msi' | 'appimage' | 'deb' | 'rpm'

export type PlatformAsset = {
  os: Os
  format: AssetFormat
  recommended: boolean
  url: string              // GitHub asset browser_download_url
  sizeBytes: number
  filename: string
}

export type LatestRelease = {
  version: string          // e.g. "1.1.1"
  tagName: string          // e.g. "v1.1.1"
  publishedAt: string      // ISO-8601
  assets: PlatformAsset[]
  releaseNotesUrl: string
}

export async function getLatestRelease(): Promise<LatestRelease>
export function findAsset(
  release: LatestRelease,
  os: Os,
  format?: AssetFormat,
): PlatformAsset | null
export const RECOMMENDED: Record<Os, AssetFormat>  // mac → dmg, windows → exe, linux → appimage
export const GITHUB_RELEASES_URL: string           // "https://github.com/matovu-farid/rishi-monorepo/releases/latest"
```

**Fetch:** GET `https://api.github.com/repos/matovu-farid/rishi-monorepo/releases/latest`, `Accept: application/vnd.github+json`, no auth token needed (rate limit is per server IP and 60/hr is plenty given caching).

**Asset classification regex:**
| Pattern (case-insensitive) | → | `os` | `format` |
|---|---|---|---|
| `\.dmg$` | | `mac` | `dmg` |
| `-setup\.exe$` or `\.exe$` | | `windows` | `exe` |
| `\.msi$` | | `windows` | `msi` |
| `\.AppImage$` | | `linux` | `appimage` |
| `\.deb$` | | `linux` | `deb` |
| `\.rpm$` | | `linux` | `rpm` |
| `\.sig$`, `latest\.json`, `\.app\.tar\.gz$` | | *(skipped)* |

`recommended = (format === RECOMMENDED[os])`.

**Cache:** wrap the fetch in `unstable_cache(fn, ['github-release-latest'], { revalidate: 600, tags: ['github-release'] })`. On fetch failure, the wrapper transparently serves the last good value until next successful revalidation.

### 4.2 `lib/detect-os.ts`

```ts
export type DetectedOs = 'mac' | 'windows' | 'linux' | 'mobile' | 'unknown'
export function detectOs(headers: Headers): DetectedOs
```

Algorithm:
1. If `user-agent` matches `/(android|iphone|ipad|ipod)/i` → `'mobile'`. (Checked first so that Android Chrome, which sends `sec-ch-ua-platform: "Android"`, is classified once here rather than routed through the desktop mapping.)
2. If `sec-ch-ua-platform` is set (stripped of quotes), map `"macOS" → 'mac'`, `"Windows" → 'windows'`, `"Linux" → 'linux'`. `"Android"`/`"iOS"` also map to `'mobile'`, but are normally caught in step 1.
3. Else parse `user-agent`: `Mac OS X`/`Macintosh` → `mac`, `Windows NT` → `windows`, `Linux` → `linux`.
4. Else `'unknown'`.

When both signals are available and non-mobile, `sec-ch-ua-platform` wins (it's the reason step 2 runs before step 3).

### 4.3 `components/download-button-server.tsx`

```tsx
// Server component — async
export async function DownloadButtonServer({
  variant,
}: { variant: 'primary' | 'header' }) {
  const hdrs = await headers()
  const detectedOs = detectOs(hdrs)
  const release = await getLatestRelease().catch(() => null)
  return (
    <DownloadButton variant={variant} detectedOs={detectedOs} release={release} />
  )
}
```

Each placement (Hero, CTA, Header) imports this. React's request-scoped memoization + `unstable_cache` means `getLatestRelease()` runs at most once per render even though it's called three times.

### 4.4 `components/download-button.tsx` (client)

Receives `{ variant, detectedOs, release }`. Stateless w.r.t. data; uses `useState` only for the per-OS expanded/collapsed state inside the dropdown.

Uses `@radix-ui/react-dropdown-menu` with a trigger split across two elements: the primary anchor (label) and a chevron button (dropdown trigger) inside a single visually-unified pill.

Renders the fallback UI (`Download from GitHub` + single-item dropdown) when `release === null`.

### 4.5 API routes

**`app/api/latest-release/route.ts`**
```ts
export async function GET() {
  try {
    const release = await getLatestRelease()
    return NextResponse.json(release, {
      headers: { 'Cache-Control': 'public, s-maxage=600, stale-while-revalidate=86400' },
    })
  } catch {
    return NextResponse.json({ error: 'unavailable' }, { status: 503 })
  }
}
```

**`app/api/download/[os]/route.ts`**
```ts
export async function GET(
  req: Request,
  { params }: { params: Promise<{ os: string }> },
) {
  const { os } = await params
  if (!isValidOs(os)) return new Response('Not found', { status: 404 })
  const format = new URL(req.url).searchParams.get('format') ?? undefined
  if (format && !isValidFormat(format)) return new Response('Not found', { status: 404 })

  try {
    const release = await getLatestRelease()
    const asset = findAsset(release, os, format as AssetFormat | undefined)
    if (!asset) return NextResponse.redirect(GITHUB_RELEASES_URL, 302)
    return NextResponse.redirect(asset.url, 302)
  } catch {
    return NextResponse.redirect(GITHUB_RELEASES_URL, 302)
  }
}
```

Both routes run on the Node runtime (default for `app/api/**/route.ts`). No edge-specific code.

## 5. Integration into existing components

| File | Change |
|---|---|
| `apps/web/src/components/hero.tsx` | Replace `<button>Get Started</button>` with `<DownloadButtonServer variant="primary" />`. Keep Watch Demo button. `Hero` becomes `async` (it's already a server component — no `"use client"` directive). |
| `apps/web/src/components/cta.tsx` | Replace `<button>Download Now</button>` with `<DownloadButtonServer variant="primary" />`. Keep Learn More and the "Available for Mac, Windows, and Linux" caption. |
| `apps/web/src/components/header.tsx` | Replace both inert `<button>Download App</button>` instances with `<DownloadButtonServer variant="header" />`. The header is currently `"use client"`; swap to a server wrapper or pass the fetched data in via a shared layout. See note below. |
| `apps/web/src/app/page.tsx` | No direct change needed — children fetch their own data. |

**Header caveat:** because `header.tsx` is `"use client"` (it manages mobile-menu open state), we can't drop a server component inside it. Solution: split the header into a server shell (`header.tsx`, renders the Download button server-side) and a client child (`header-mobile-menu.tsx`, handles hamburger open state). The Download button itself is passed as a child ReactNode so the mobile menu can include it.

## 6. Error handling & fallbacks

| Scenario | Behavior |
|---|---|
| GitHub fetch succeeds | Normal rendering. |
| Fetch fails, cache has last-known-good | Cache used transparently by `unstable_cache`. User sees normal button. |
| Fetch fails, no cache (cold deploy during outage) | Button renders `⬇ Download from GitHub` linking to `releases/latest`. Dropdown shows a single "Open GitHub Releases" item. |
| `/api/download/[os]` fetches, no matching asset | Redirect to `releases/latest`. |
| `/api/download/[os]` fetches, fetch throws | Redirect to `releases/latest`. |
| Invalid `os` or `format` in URL | 404. |

## 7. Testing approach

- **Unit — `lib/releases.ts`**
  - `parseAssets()` given a mocked GitHub response produces the expected `PlatformAsset[]` with correct `recommended` flags.
  - `.sig`, `latest.json`, `.app.tar.gz` are filtered out.
  - `findAsset(release, 'windows')` returns the `.exe`; `findAsset(release, 'windows', 'msi')` returns the `.msi`.
- **Unit — `lib/detect-os.ts`**
  - Fixture UA strings for: macOS Safari, macOS Chrome, Windows Chrome, Windows Edge, Ubuntu Firefox, Android Chrome, iOS Safari, iPadOS Safari (`iPad`), unknown/empty. Assert correct `DetectedOs`.
  - `sec-ch-ua-platform` takes precedence over UA when present.
- **Route tests**
  - `/api/download/mac` → 302 to `.dmg` URL.
  - `/api/download/windows?format=msi` → 302 to `.msi` URL.
  - `/api/download/windows?format=bogus` → 404.
  - `/api/download/linux` → 302 to `.AppImage` URL.
  - `/api/download/mars` → 404.
  - `/api/latest-release` returns the parsed JSON.
- **Component smoke test**
  - `DownloadButton` with `detectedOs="mac"` renders label "Download for macOS".
  - With `detectedOs="mobile"` renders "Download for Desktop" + "Mobile coming soon".
  - With `release=null` renders "Download from GitHub".
  - Dropdown opens on chevron click; Windows/Linux rows expand to reveal alternates.

Tests live alongside source (`*.test.ts[x]`) and run with whatever test harness `apps/web` uses (none today — we'll introduce Vitest with a minimal config as part of the implementation plan).

## 8. Out of scope

- Signed checksum display, SHA verification UI, homebrew / winget / AUR install instructions. Possible follow-up.
- Download analytics beyond what `@vercel/analytics` (already integrated) observes from page and click events — no custom server-side counter.
- A dedicated `/download` page — the CTAs are the download surface.
- ARM64 builds (Windows-on-ARM, Linux ARM). When release assets grow to include them, extend `AssetFormat` and re-test; no architectural change required.
