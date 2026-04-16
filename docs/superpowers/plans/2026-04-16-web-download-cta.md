# Web Download CTA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the three inert "Download" CTAs on the marketing site into working download buttons that auto-detect the visitor's OS, pick the right binary from the latest GitHub release, and let users switch platform/format via a split-button dropdown.

**Architecture:** Small server-only `lib/releases.ts` fetches and parses GitHub's latest-release JSON (cached via `unstable_cache`). `lib/detect-os.ts` classifies the OS from request headers. A server component wrapper gathers both and passes them to a client split-button component built on `@radix-ui/react-dropdown-menu`. Two API routes back click navigation: `/api/download/[os]` 302s to the latest asset URL; `/api/latest-release` exposes the parsed release as JSON.

**Tech Stack:** Next.js 16 (App Router), React 19, TypeScript, Tailwind 4, Radix UI, Vitest + Testing Library + happy-dom.

**Reference spec:** `docs/superpowers/specs/2026-04-16-web-download-cta-design.md`

---

## File Structure

```
apps/web/
├── package.json                                     — add vitest + testing deps, add test scripts
├── vitest.config.ts                                 — new; Vitest config for apps/web
├── vitest.setup.ts                                  — new; Testing Library jest-dom setup
└── src/
    ├── lib/
    │   ├── releases.ts                              — new; GitHub fetch + parse + cache + helpers
    │   ├── releases.test.ts                         — new; unit tests for parser + findAsset
    │   ├── detect-os.ts                             — new; detectOs(headers) util
    │   └── detect-os.test.ts                        — new; unit tests for detectOs
    ├── app/api/
    │   ├── latest-release/route.ts                  — new; GET → JSON of parsed release
    │   ├── latest-release/route.test.ts             — new; route handler test
    │   ├── download/[os]/route.ts                   — new; GET → 302 to asset URL
    │   └── download/[os]/route.test.ts              — new; route handler test
    └── components/
        ├── download-button.tsx                      — new; client split-button + dropdown
        ├── download-button.test.tsx                 — new; component tests
        ├── download-button-server.tsx               — new; async server wrapper
        ├── hero.tsx                                 — modify; swap Get Started button
        ├── cta.tsx                                  — modify; swap Download Now button
        ├── header.tsx                               — modify; split into server shell
        └── header-mobile-menu.tsx                   — new; client half of the header
```

---

## Task 1: Add Vitest test harness to apps/web

**Files:**
- Modify: `apps/web/package.json`
- Create: `apps/web/vitest.config.ts`
- Create: `apps/web/vitest.setup.ts`

- [ ] **Step 1: Install test dependencies**

Run from the repo root:

```bash
cd apps/web && bun add -D vitest @vitest/ui happy-dom @testing-library/react @testing-library/jest-dom @testing-library/user-event @vitejs/plugin-react
```

Expected: dependencies added to `apps/web/package.json` under `devDependencies` and `bun.lockb` updated.

- [ ] **Step 2: Add test scripts to `apps/web/package.json`**

Edit `apps/web/package.json`. In the `"scripts"` object, add two scripts so it reads:

```json
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "eslint .",
    "test": "vitest run",
    "test:watch": "vitest"
  },
```

- [ ] **Step 3: Create `apps/web/vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import path from "node:path";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "happy-dom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
    include: ["src/**/*.{test,spec}.{ts,tsx}"],
  },
});
```

- [ ] **Step 4: Create `apps/web/vitest.setup.ts`**

```ts
import "@testing-library/jest-dom/vitest";
```

- [ ] **Step 5: Add a sanity test to prove the harness works**

Create `apps/web/src/lib/sanity.test.ts`:

```ts
import { describe, it, expect } from "vitest";

describe("vitest harness", () => {
  it("runs", () => {
    expect(1 + 1).toBe(2);
  });
});
```

- [ ] **Step 6: Run the test to verify**

Run: `cd apps/web && bun run test`
Expected: 1 passing test, 0 failing.

- [ ] **Step 7: Delete the sanity test**

```bash
rm apps/web/src/lib/sanity.test.ts
```

- [ ] **Step 8: Commit**

```bash
git add apps/web/package.json apps/web/bun.lockb apps/web/vitest.config.ts apps/web/vitest.setup.ts
git commit -m "test(web): add vitest harness with happy-dom + testing-library"
```

---

## Task 2: Release parser — types, `parseGithubRelease`, `findAsset`, constants

**Files:**
- Create: `apps/web/src/lib/releases.ts`
- Create: `apps/web/src/lib/releases.test.ts`

- [ ] **Step 1: Write the failing test**

Create `apps/web/src/lib/releases.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  parseGithubRelease,
  findAsset,
  RECOMMENDED,
  GITHUB_RELEASES_URL,
  type GithubApiRelease,
} from "./releases";

function makeAsset(name: string, size = 1234): GithubApiRelease["assets"][number] {
  return {
    name,
    size,
    browser_download_url: `https://example.com/${name}`,
  };
}

const FIXTURE: GithubApiRelease = {
  tag_name: "v1.1.1",
  name: "Rishi v1.1.1",
  published_at: "2026-04-16T18:03:16Z",
  html_url: "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
  assets: [
    makeAsset("rishi_1.1.1_universal.dmg", 98_000_000),
    makeAsset("rishi_1.1.1_x64-setup.exe", 80_000_000),
    makeAsset("rishi_1.1.1_x64-setup.exe.sig", 200),
    makeAsset("rishi_1.1.1_x64_en-US.msi", 82_000_000),
    makeAsset("rishi_1.1.1_x64_en-US.msi.sig", 200),
    makeAsset("rishi_1.1.1_amd64.AppImage", 90_000_000),
    makeAsset("rishi_1.1.1_amd64.AppImage.sig", 200),
    makeAsset("rishi_1.1.1_amd64.deb", 60_000_000),
    makeAsset("rishi_1.1.1_amd64.deb.sig", 200),
    makeAsset("rishi-1.1.1-1.x86_64.rpm", 60_000_000),
    makeAsset("rishi-1.1.1-1.x86_64.rpm.sig", 200),
    makeAsset("rishi_universal.app.tar.gz", 95_000_000),
    makeAsset("rishi_universal.app.tar.gz.sig", 200),
    makeAsset("latest.json", 512),
  ],
};

describe("parseGithubRelease", () => {
  it("extracts version, tag, publish date, and notes URL", () => {
    const release = parseGithubRelease(FIXTURE);
    expect(release.version).toBe("1.1.1");
    expect(release.tagName).toBe("v1.1.1");
    expect(release.publishedAt).toBe("2026-04-16T18:03:16Z");
    expect(release.releaseNotesUrl).toBe(
      "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
    );
  });

  it("keeps version intact when tag has no leading v", () => {
    const release = parseGithubRelease({ ...FIXTURE, tag_name: "1.2.3" });
    expect(release.version).toBe("1.2.3");
    expect(release.tagName).toBe("1.2.3");
  });

  it("classifies one asset per installer format", () => {
    const release = parseGithubRelease(FIXTURE);
    const filenames = release.assets.map((a) => a.filename).sort();
    expect(filenames).toEqual(
      [
        "rishi-1.1.1-1.x86_64.rpm",
        "rishi_1.1.1_amd64.AppImage",
        "rishi_1.1.1_amd64.deb",
        "rishi_1.1.1_universal.dmg",
        "rishi_1.1.1_x64-setup.exe",
        "rishi_1.1.1_x64_en-US.msi",
      ].sort(),
    );
  });

  it("filters out .sig, latest.json, and .app.tar.gz assets", () => {
    const release = parseGithubRelease(FIXTURE);
    const filenames = release.assets.map((a) => a.filename);
    expect(filenames).not.toContain("latest.json");
    expect(filenames).not.toContain("rishi_universal.app.tar.gz");
    for (const f of filenames) {
      expect(f.endsWith(".sig")).toBe(false);
    }
  });

  it("marks recommended formats per OS", () => {
    const release = parseGithubRelease(FIXTURE);
    const recommended = release.assets.filter((a) => a.recommended);
    const recommendedByOs = Object.fromEntries(recommended.map((a) => [a.os, a.format]));
    expect(recommendedByOs).toEqual({
      mac: "dmg",
      windows: "exe",
      linux: "appimage",
    });
  });

  it("populates url, sizeBytes, and filename on each asset", () => {
    const release = parseGithubRelease(FIXTURE);
    const dmg = release.assets.find((a) => a.format === "dmg")!;
    expect(dmg.url).toBe("https://example.com/rishi_1.1.1_universal.dmg");
    expect(dmg.sizeBytes).toBe(98_000_000);
    expect(dmg.filename).toBe("rishi_1.1.1_universal.dmg");
  });
});

describe("findAsset", () => {
  const release = parseGithubRelease(FIXTURE);

  it("returns the recommended asset when format is omitted", () => {
    expect(findAsset(release, "mac")?.format).toBe("dmg");
    expect(findAsset(release, "windows")?.format).toBe("exe");
    expect(findAsset(release, "linux")?.format).toBe("appimage");
  });

  it("returns the requested format when specified", () => {
    expect(findAsset(release, "windows", "msi")?.format).toBe("msi");
    expect(findAsset(release, "linux", "deb")?.format).toBe("deb");
    expect(findAsset(release, "linux", "rpm")?.format).toBe("rpm");
  });

  it("returns null for a format that does not exist on that OS", () => {
    expect(findAsset(release, "mac", "exe")).toBeNull();
    expect(findAsset(release, "windows", "dmg")).toBeNull();
  });
});

describe("constants", () => {
  it("RECOMMENDED maps each OS to its default format", () => {
    expect(RECOMMENDED).toEqual({ mac: "dmg", windows: "exe", linux: "appimage" });
  });

  it("GITHUB_RELEASES_URL points at the repo's releases/latest", () => {
    expect(GITHUB_RELEASES_URL).toBe(
      "https://github.com/matovu-farid/rishi-monorepo/releases/latest",
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/web && bun run test src/lib/releases.test.ts`
Expected: FAIL — `Cannot find module './releases'`.

- [ ] **Step 3: Create `apps/web/src/lib/releases.ts` with the minimum to make tests pass**

```ts
import { unstable_cache } from "next/cache";

export type Os = "mac" | "windows" | "linux";
export type AssetFormat = "dmg" | "exe" | "msi" | "appimage" | "deb" | "rpm";

export type PlatformAsset = {
  os: Os;
  format: AssetFormat;
  recommended: boolean;
  url: string;
  sizeBytes: number;
  filename: string;
};

export type LatestRelease = {
  version: string;
  tagName: string;
  publishedAt: string;
  assets: PlatformAsset[];
  releaseNotesUrl: string;
};

export type GithubApiRelease = {
  tag_name: string;
  name: string;
  published_at: string;
  html_url: string;
  assets: Array<{
    name: string;
    size: number;
    browser_download_url: string;
  }>;
};

export const RECOMMENDED: Record<Os, AssetFormat> = {
  mac: "dmg",
  windows: "exe",
  linux: "appimage",
};

export const GITHUB_RELEASES_URL =
  "https://github.com/matovu-farid/rishi-monorepo/releases/latest";

const GITHUB_API_URL =
  "https://api.github.com/repos/matovu-farid/rishi-monorepo/releases/latest";

type Classification = { os: Os; format: AssetFormat } | null;

function classify(filename: string): Classification {
  const lower = filename.toLowerCase();
  if (lower.endsWith(".sig")) return null;
  if (lower === "latest.json") return null;
  if (lower.endsWith(".app.tar.gz")) return null;
  if (lower.endsWith(".dmg")) return { os: "mac", format: "dmg" };
  if (lower.endsWith(".msi")) return { os: "windows", format: "msi" };
  if (lower.endsWith(".exe")) return { os: "windows", format: "exe" };
  if (lower.endsWith(".appimage")) return { os: "linux", format: "appimage" };
  if (lower.endsWith(".deb")) return { os: "linux", format: "deb" };
  if (lower.endsWith(".rpm")) return { os: "linux", format: "rpm" };
  return null;
}

export function parseGithubRelease(raw: GithubApiRelease): LatestRelease {
  const version = raw.tag_name.startsWith("v") ? raw.tag_name.slice(1) : raw.tag_name;

  const assets: PlatformAsset[] = [];
  for (const a of raw.assets) {
    const hit = classify(a.name);
    if (!hit) continue;
    assets.push({
      os: hit.os,
      format: hit.format,
      recommended: RECOMMENDED[hit.os] === hit.format,
      url: a.browser_download_url,
      sizeBytes: a.size,
      filename: a.name,
    });
  }

  return {
    version,
    tagName: raw.tag_name,
    publishedAt: raw.published_at,
    assets,
    releaseNotesUrl: raw.html_url,
  };
}

export function findAsset(
  release: LatestRelease,
  os: Os,
  format?: AssetFormat,
): PlatformAsset | null {
  const wanted = format ?? RECOMMENDED[os];
  return release.assets.find((a) => a.os === os && a.format === wanted) ?? null;
}

async function fetchRelease(): Promise<LatestRelease> {
  const res = await fetch(GITHUB_API_URL, {
    headers: { Accept: "application/vnd.github+json" },
  });
  if (!res.ok) {
    throw new Error(`GitHub API returned ${res.status}`);
  }
  const raw = (await res.json()) as GithubApiRelease;
  return parseGithubRelease(raw);
}

export const getLatestRelease = unstable_cache(fetchRelease, ["github-release-latest"], {
  revalidate: 600,
  tags: ["github-release"],
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/web && bun run test src/lib/releases.test.ts`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/web/src/lib/releases.ts apps/web/src/lib/releases.test.ts
git commit -m "feat(web): add GitHub release parser and asset finder"
```

---

## Task 3: OS detection — `detectOs(headers)`

**Files:**
- Create: `apps/web/src/lib/detect-os.ts`
- Create: `apps/web/src/lib/detect-os.test.ts`

- [ ] **Step 1: Write the failing test**

Create `apps/web/src/lib/detect-os.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { detectOs } from "./detect-os";

function headers(entries: Record<string, string>): Headers {
  return new Headers(entries);
}

describe("detectOs", () => {
  it("detects macOS from sec-ch-ua-platform", () => {
    expect(detectOs(headers({ "sec-ch-ua-platform": '"macOS"' }))).toBe("mac");
  });

  it("detects Windows from sec-ch-ua-platform", () => {
    expect(detectOs(headers({ "sec-ch-ua-platform": '"Windows"' }))).toBe("windows");
  });

  it("detects Linux from sec-ch-ua-platform", () => {
    expect(detectOs(headers({ "sec-ch-ua-platform": '"Linux"' }))).toBe("linux");
  });

  it("detects mobile via user-agent even when sec-ch-ua-platform says Android", () => {
    expect(
      detectOs(
        headers({
          "sec-ch-ua-platform": '"Android"',
          "user-agent":
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120",
        }),
      ),
    ).toBe("mobile");
  });

  it("detects mobile from iPhone UA", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605",
        }),
      ),
    ).toBe("mobile");
  });

  it("detects mobile from iPad UA", () => {
    expect(
      detectOs(
        headers({
          "user-agent": "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605",
        }),
      ),
    ).toBe("mobile");
  });

  it("falls back to UA parsing when sec-ch-ua-platform is absent — macOS", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605 Safari/605",
        }),
      ),
    ).toBe("mac");
  });

  it("falls back to UA parsing — Windows", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120",
        }),
      ),
    ).toBe("windows");
  });

  it("falls back to UA parsing — Linux", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120",
        }),
      ),
    ).toBe("linux");
  });

  it("returns unknown for empty headers", () => {
    expect(detectOs(headers({}))).toBe("unknown");
  });

  it("returns unknown for unrecognized UA", () => {
    expect(detectOs(headers({ "user-agent": "Weirdbot/1.0" }))).toBe("unknown");
  });

  it("prefers sec-ch-ua-platform over UA for desktop classification", () => {
    // UA says Windows, CH says macOS — CH should win
    expect(
      detectOs(
        headers({
          "sec-ch-ua-platform": '"macOS"',
          "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120",
        }),
      ),
    ).toBe("mac");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/web && bun run test src/lib/detect-os.test.ts`
Expected: FAIL — `Cannot find module './detect-os'`.

- [ ] **Step 3: Create `apps/web/src/lib/detect-os.ts`**

```ts
export type DetectedOs = "mac" | "windows" | "linux" | "mobile" | "unknown";

export function detectOs(headers: Headers): DetectedOs {
  const ua = headers.get("user-agent") ?? "";

  // 1. Mobile UAs win, even if sec-ch-ua-platform says "Android"
  if (/android|iphone|ipad|ipod/i.test(ua)) {
    return "mobile";
  }

  // 2. sec-ch-ua-platform (quotes included in the header value)
  const rawPlatform = headers.get("sec-ch-ua-platform");
  if (rawPlatform) {
    const platform = rawPlatform.replace(/^"|"$/g, "");
    if (platform === "macOS") return "mac";
    if (platform === "Windows") return "windows";
    if (platform === "Linux") return "linux";
    if (platform === "Android" || platform === "iOS") return "mobile";
  }

  // 3. UA fallback
  if (/Mac OS X|Macintosh/i.test(ua)) return "mac";
  if (/Windows NT/i.test(ua)) return "windows";
  if (/Linux/i.test(ua)) return "linux";

  return "unknown";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/web && bun run test src/lib/detect-os.test.ts`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/web/src/lib/detect-os.ts apps/web/src/lib/detect-os.test.ts
git commit -m "feat(web): add OS detection from request headers"
```

---

## Task 4: `/api/download/[os]/route.ts` — redirect endpoint

**Files:**
- Create: `apps/web/src/app/api/download/[os]/route.ts`
- Create: `apps/web/src/app/api/download/[os]/route.test.ts`

- [ ] **Step 1: Write the failing test**

Create `apps/web/src/app/api/download/[os]/route.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { LatestRelease } from "@/lib/releases";

// Mock the releases module so the route handler can be tested without network.
vi.mock("@/lib/releases", async () => {
  const actual =
    await vi.importActual<typeof import("@/lib/releases")>("@/lib/releases");
  return {
    ...actual,
    getLatestRelease: vi.fn(),
  };
});

import { getLatestRelease } from "@/lib/releases";
import { GET } from "./route";

const RELEASE: LatestRelease = {
  version: "1.1.1",
  tagName: "v1.1.1",
  publishedAt: "2026-04-16T18:03:16Z",
  releaseNotesUrl: "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
  assets: [
    {
      os: "mac",
      format: "dmg",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_universal.dmg",
      sizeBytes: 1,
      filename: "rishi_1.1.1_universal.dmg",
    },
    {
      os: "windows",
      format: "exe",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_x64-setup.exe",
      sizeBytes: 1,
      filename: "rishi_1.1.1_x64-setup.exe",
    },
    {
      os: "windows",
      format: "msi",
      recommended: false,
      url: "https://example.com/rishi_1.1.1_x64_en-US.msi",
      sizeBytes: 1,
      filename: "rishi_1.1.1_x64_en-US.msi",
    },
    {
      os: "linux",
      format: "appimage",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_amd64.AppImage",
      sizeBytes: 1,
      filename: "rishi_1.1.1_amd64.AppImage",
    },
  ],
};

const GITHUB_FALLBACK = "https://github.com/matovu-farid/rishi-monorepo/releases/latest";

function mockRequest(url: string): Request {
  return new Request(url);
}

function asyncParams(os: string) {
  return Promise.resolve({ os });
}

beforeEach(() => {
  vi.mocked(getLatestRelease).mockReset();
});

describe("GET /api/download/[os]", () => {
  it("redirects 302 to the .dmg for os=mac", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/mac"), {
      params: asyncParams("mac"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_universal.dmg",
    );
  });

  it("redirects 302 to the .exe for os=windows (default format)", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/windows"), {
      params: asyncParams("windows"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_x64-setup.exe",
    );
  });

  it("redirects 302 to the .msi when format=msi", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/windows?format=msi"), {
      params: asyncParams("windows"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_x64_en-US.msi",
    );
  });

  it("redirects 302 to the .AppImage for os=linux (default)", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/linux"), {
      params: asyncParams("linux"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(
      "https://example.com/rishi_1.1.1_amd64.AppImage",
    );
  });

  it("returns 404 for an invalid os", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(mockRequest("https://site.test/api/download/mars"), {
      params: asyncParams("mars"),
    });
    expect(res.status).toBe(404);
  });

  it("returns 404 for an invalid format", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET(
      mockRequest("https://site.test/api/download/windows?format=bogus"),
      { params: asyncParams("windows") },
    );
    expect(res.status).toBe(404);
  });

  it("redirects to the GitHub releases page when an asset is missing", async () => {
    const partial: LatestRelease = { ...RELEASE, assets: [] };
    vi.mocked(getLatestRelease).mockResolvedValue(partial);
    const res = await GET(mockRequest("https://site.test/api/download/mac"), {
      params: asyncParams("mac"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(GITHUB_FALLBACK);
  });

  it("redirects to the GitHub releases page when the fetch throws", async () => {
    vi.mocked(getLatestRelease).mockRejectedValue(new Error("boom"));
    const res = await GET(mockRequest("https://site.test/api/download/mac"), {
      params: asyncParams("mac"),
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(GITHUB_FALLBACK);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/web && bun run test src/app/api/download`
Expected: FAIL — `Cannot find module './route'`.

- [ ] **Step 3: Create the route handler**

Create `apps/web/src/app/api/download/[os]/route.ts`:

```ts
import { NextResponse } from "next/server";
import {
  findAsset,
  getLatestRelease,
  GITHUB_RELEASES_URL,
  type AssetFormat,
  type Os,
} from "@/lib/releases";

const VALID_OS: readonly string[] = ["mac", "windows", "linux"];
const VALID_FORMATS: readonly string[] = [
  "dmg",
  "exe",
  "msi",
  "appimage",
  "deb",
  "rpm",
];

export async function GET(
  req: Request,
  { params }: { params: Promise<{ os: string }> },
) {
  const { os } = await params;
  if (!VALID_OS.includes(os)) {
    return new NextResponse("Not found", { status: 404 });
  }

  const formatParam = new URL(req.url).searchParams.get("format");
  if (formatParam !== null && !VALID_FORMATS.includes(formatParam)) {
    return new NextResponse("Not found", { status: 404 });
  }

  try {
    const release = await getLatestRelease();
    const asset = findAsset(
      release,
      os as Os,
      (formatParam ?? undefined) as AssetFormat | undefined,
    );
    if (!asset) {
      return NextResponse.redirect(GITHUB_RELEASES_URL, 302);
    }
    return NextResponse.redirect(asset.url, 302);
  } catch {
    return NextResponse.redirect(GITHUB_RELEASES_URL, 302);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/web && bun run test src/app/api/download`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/web/src/app/api/download
git commit -m "feat(web): add /api/download/[os] redirect endpoint"
```

---

## Task 5: `/api/latest-release/route.ts` — JSON endpoint

**Files:**
- Create: `apps/web/src/app/api/latest-release/route.ts`
- Create: `apps/web/src/app/api/latest-release/route.test.ts`

- [ ] **Step 1: Write the failing test**

Create `apps/web/src/app/api/latest-release/route.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { LatestRelease } from "@/lib/releases";

vi.mock("@/lib/releases", async () => {
  const actual =
    await vi.importActual<typeof import("@/lib/releases")>("@/lib/releases");
  return {
    ...actual,
    getLatestRelease: vi.fn(),
  };
});

import { getLatestRelease } from "@/lib/releases";
import { GET } from "./route";

const RELEASE: LatestRelease = {
  version: "1.1.1",
  tagName: "v1.1.1",
  publishedAt: "2026-04-16T18:03:16Z",
  releaseNotesUrl: "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
  assets: [],
};

beforeEach(() => {
  vi.mocked(getLatestRelease).mockReset();
});

describe("GET /api/latest-release", () => {
  it("returns the parsed release as JSON", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.version).toBe("1.1.1");
  });

  it("sets a cache-control header allowing CDN caching", async () => {
    vi.mocked(getLatestRelease).mockResolvedValue(RELEASE);
    const res = await GET();
    const cacheControl = res.headers.get("cache-control") ?? "";
    expect(cacheControl).toMatch(/s-maxage=600/);
    expect(cacheControl).toMatch(/stale-while-revalidate=86400/);
  });

  it("returns 503 when the release fetch fails", async () => {
    vi.mocked(getLatestRelease).mockRejectedValue(new Error("boom"));
    const res = await GET();
    expect(res.status).toBe(503);
    const body = await res.json();
    expect(body.error).toBe("unavailable");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/web && bun run test src/app/api/latest-release`
Expected: FAIL — module missing.

- [ ] **Step 3: Create the route handler**

Create `apps/web/src/app/api/latest-release/route.ts`:

```ts
import { NextResponse } from "next/server";
import { getLatestRelease } from "@/lib/releases";

export async function GET() {
  try {
    const release = await getLatestRelease();
    return NextResponse.json(release, {
      headers: {
        "Cache-Control": "public, s-maxage=600, stale-while-revalidate=86400",
      },
    });
  } catch {
    return NextResponse.json({ error: "unavailable" }, { status: 503 });
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/web && bun run test src/app/api/latest-release`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/web/src/app/api/latest-release
git commit -m "feat(web): add /api/latest-release JSON endpoint"
```

---

## Task 6: `DownloadButton` client component

**Files:**
- Create: `apps/web/src/components/download-button.tsx`
- Create: `apps/web/src/components/download-button.test.tsx`

The component is intentionally stateless w.r.t. data — all inputs come via props. The only local state is the per-OS expanded/collapsed state inside the dropdown.

- [ ] **Step 1: Write the failing test**

Create `apps/web/src/components/download-button.test.tsx`:

```tsx
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { LatestRelease } from "@/lib/releases";
import { DownloadButton } from "./download-button";

const RELEASE: LatestRelease = {
  version: "1.1.1",
  tagName: "v1.1.1",
  publishedAt: "2026-04-16T18:03:16Z",
  releaseNotesUrl: "https://github.com/matovu-farid/rishi-monorepo/releases/tag/v1.1.1",
  assets: [
    {
      os: "mac",
      format: "dmg",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_universal.dmg",
      sizeBytes: 1,
      filename: "rishi_1.1.1_universal.dmg",
    },
    {
      os: "windows",
      format: "exe",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_x64-setup.exe",
      sizeBytes: 1,
      filename: "rishi_1.1.1_x64-setup.exe",
    },
    {
      os: "windows",
      format: "msi",
      recommended: false,
      url: "https://example.com/rishi_1.1.1_x64_en-US.msi",
      sizeBytes: 1,
      filename: "rishi_1.1.1_x64_en-US.msi",
    },
    {
      os: "linux",
      format: "appimage",
      recommended: true,
      url: "https://example.com/rishi_1.1.1_amd64.AppImage",
      sizeBytes: 1,
      filename: "rishi_1.1.1_amd64.AppImage",
    },
    {
      os: "linux",
      format: "deb",
      recommended: false,
      url: "https://example.com/rishi_1.1.1_amd64.deb",
      sizeBytes: 1,
      filename: "rishi_1.1.1_amd64.deb",
    },
    {
      os: "linux",
      format: "rpm",
      recommended: false,
      url: "https://example.com/rishi-1.1.1-1.x86_64.rpm",
      sizeBytes: 1,
      filename: "rishi-1.1.1-1.x86_64.rpm",
    },
  ],
};

describe("<DownloadButton>", () => {
  it("renders 'Download for macOS' when detectedOs is mac", () => {
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);
    expect(
      screen.getByRole("link", { name: /download for macos/i }),
    ).toHaveAttribute("href", "/api/download/mac");
  });

  it("renders 'Download for Windows' when detectedOs is windows", () => {
    render(
      <DownloadButton variant="primary" detectedOs="windows" release={RELEASE} />,
    );
    expect(
      screen.getByRole("link", { name: /download for windows/i }),
    ).toHaveAttribute("href", "/api/download/windows");
  });

  it("renders 'Download for Desktop' + 'Mobile coming soon' when mobile", () => {
    render(<DownloadButton variant="primary" detectedOs="mobile" release={RELEASE} />);
    expect(
      screen.getByRole("link", { name: /download for desktop/i }),
    ).toHaveAttribute("href", "/api/download/mac");
    expect(screen.getByText(/mobile coming soon/i)).toBeInTheDocument();
  });

  it("renders 'Download for Desktop' when detectedOs is unknown", () => {
    render(<DownloadButton variant="primary" detectedOs="unknown" release={RELEASE} />);
    expect(
      screen.getByRole("link", { name: /download for desktop/i }),
    ).toHaveAttribute("href", "/api/download/mac");
  });

  it("does not render 'Mobile coming soon' in header variant", () => {
    render(<DownloadButton variant="header" detectedOs="mobile" release={RELEASE} />);
    expect(screen.queryByText(/mobile coming soon/i)).not.toBeInTheDocument();
  });

  it("renders 'Download from GitHub' when release is null", () => {
    render(<DownloadButton variant="primary" detectedOs="mac" release={null} />);
    expect(
      screen.getByRole("link", { name: /download from github/i }),
    ).toHaveAttribute(
      "href",
      "https://github.com/matovu-farid/rishi-monorepo/releases/latest",
    );
  });

  it("opens the dropdown when the chevron is clicked and lists all three OSes", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));

    expect(await screen.findByRole("menuitem", { name: /macos/i })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /windows/i })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /linux/i })).toBeInTheDocument();
  });

  it("expands Windows alternate formats when the Windows expand caret is clicked", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));
    await user.click(
      await screen.findByRole("button", { name: /more windows formats/i }),
    );

    expect(
      await screen.findByRole("menuitem", { name: /msi installer/i }),
    ).toHaveAttribute("href", "/api/download/windows?format=msi");
  });

  it("expands Linux alternate formats when the Linux expand caret is clicked", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));
    await user.click(
      await screen.findByRole("button", { name: /more linux formats/i }),
    );

    expect(
      await screen.findByRole("menuitem", { name: /debian package/i }),
    ).toHaveAttribute("href", "/api/download/linux?format=deb");
    expect(
      screen.getByRole("menuitem", { name: /fedora \/ rhel/i }),
    ).toHaveAttribute("href", "/api/download/linux?format=rpm");
  });

  it("exposes a 'See all releases on GitHub' link in the dropdown", async () => {
    const user = userEvent.setup();
    render(<DownloadButton variant="primary" detectedOs="mac" release={RELEASE} />);

    await user.click(screen.getByRole("button", { name: /other platforms/i }));

    const githubLink = await screen.findByRole("menuitem", {
      name: /see all releases on github/i,
    });
    expect(githubLink).toHaveAttribute(
      "href",
      "https://github.com/matovu-farid/rishi-monorepo/releases/latest",
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/web && bun run test src/components/download-button`
Expected: FAIL — module missing.

- [ ] **Step 3: Create the client component**

Create `apps/web/src/components/download-button.tsx`:

```tsx
"use client";

import { useState } from "react";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { ChevronDown, ChevronUp, Download, ExternalLink } from "lucide-react";
import type { DetectedOs } from "@/lib/detect-os";
import { GITHUB_RELEASES_URL, type LatestRelease, type Os } from "@/lib/releases";
import { cn } from "@/lib/utils";

type Variant = "primary" | "header";

type Props = {
  variant: Variant;
  detectedOs: DetectedOs;
  release: LatestRelease | null;
};

const LABEL_BY_OS: Record<Os, string> = {
  mac: "macOS",
  windows: "Windows",
  linux: "Linux",
};

/** Map a detected OS to the OS whose download URL the primary button should hit. */
function primaryTargetOs(detectedOs: DetectedOs): Os {
  if (detectedOs === "mac" || detectedOs === "windows" || detectedOs === "linux") {
    return detectedOs;
  }
  return "mac"; // mobile / unknown default
}

function primaryLabel(detectedOs: DetectedOs): string {
  if (detectedOs === "mac" || detectedOs === "windows" || detectedOs === "linux") {
    return `Download for ${LABEL_BY_OS[detectedOs]}`;
  }
  return "Download for Desktop";
}

export function DownloadButton({ variant, detectedOs, release }: Props) {
  const isPrimary = variant === "primary";
  const showMobileCaption = isPrimary && (detectedOs === "mobile" || detectedOs === "unknown");

  const outerClass = cn("inline-flex flex-col items-stretch gap-2", isPrimary ? "w-full sm:w-auto" : "");
  const pillClass = cn(
    "inline-flex items-stretch rounded-full overflow-hidden bg-accent text-accent-foreground shadow-sm",
    "hover:opacity-95 transition",
    isPrimary ? "text-base" : "text-sm",
  );
  const labelClass = cn(
    "flex items-center gap-2 font-medium",
    isPrimary ? "px-6 py-3" : "px-4 py-2",
  );
  const chevronClass = cn(
    "flex items-center justify-center border-l border-black/10",
    isPrimary ? "px-3 py-3" : "px-2 py-2",
  );

  if (release === null) {
    return (
      <div className={outerClass}>
        <div className={pillClass}>
          <a
            className={labelClass}
            href={GITHUB_RELEASES_URL}
            target="_blank"
            rel="noopener noreferrer"
          >
            <Download size={isPrimary ? 20 : 16} />
            Download from GitHub
          </a>
        </div>
      </div>
    );
  }

  const targetOs = primaryTargetOs(detectedOs);

  return (
    <div className={outerClass}>
      <div className={pillClass}>
        <a className={labelClass} href={`/api/download/${targetOs}`}>
          <Download size={isPrimary ? 20 : 16} />
          {primaryLabel(detectedOs)}
        </a>
        <DropdownMenu.Root>
          <DropdownMenu.Trigger
            aria-label="Other platforms"
            className={chevronClass}
          >
            <ChevronDown size={isPrimary ? 20 : 16} />
          </DropdownMenu.Trigger>
          <DropdownMenu.Portal>
            <DropdownMenu.Content
              align="end"
              sideOffset={8}
              className="z-50 min-w-[260px] rounded-xl border border-border bg-popover text-popover-foreground p-2 shadow-lg"
            >
              <DropdownMenu.Label className="px-2 py-1 text-xs uppercase tracking-wide text-muted-foreground">
                Platform
              </DropdownMenu.Label>
              <PlatformRow
                os="mac"
                detectedOs={detectedOs}
                label="macOS (.dmg)"
                href="/api/download/mac"
                hasAlternates={false}
              />
              <PlatformRow
                os="windows"
                detectedOs={detectedOs}
                label="Windows (.exe)"
                href="/api/download/windows"
                hasAlternates
                alternates={[
                  { href: "/api/download/windows?format=msi", label: "MSI installer (.msi)" },
                ]}
              />
              <PlatformRow
                os="linux"
                detectedOs={detectedOs}
                label="Linux (.AppImage)"
                href="/api/download/linux"
                hasAlternates
                alternates={[
                  { href: "/api/download/linux?format=deb", label: "Debian package (.deb)" },
                  { href: "/api/download/linux?format=rpm", label: "Fedora / RHEL (.rpm)" },
                ]}
              />
              <DropdownMenu.Separator className="my-1 border-t border-border" />
              <DropdownMenu.Item asChild>
                <a
                  href={GITHUB_RELEASES_URL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-2 px-2 py-2 rounded-md hover:bg-muted text-sm"
                >
                  <ExternalLink size={14} />
                  See all releases on GitHub
                </a>
              </DropdownMenu.Item>
            </DropdownMenu.Content>
          </DropdownMenu.Portal>
        </DropdownMenu.Root>
      </div>
      {showMobileCaption && (
        <p className="text-xs text-muted-foreground text-center">Mobile coming soon</p>
      )}
    </div>
  );
}

type Alternate = { href: string; label: string };

function PlatformRow({
  os,
  detectedOs,
  label,
  href,
  hasAlternates,
  alternates = [],
}: {
  os: Os;
  detectedOs: DetectedOs;
  label: string;
  href: string;
  hasAlternates: boolean;
  alternates?: Alternate[];
}) {
  const [expanded, setExpanded] = useState(false);
  const isDetected = detectedOs === os;
  const rowClass = cn(
    "flex items-center justify-between gap-2 px-2 py-2 rounded-md",
    isDetected ? "bg-accent/30" : "hover:bg-muted",
  );

  return (
    <>
      <div className={rowClass}>
        <DropdownMenu.Item asChild className="flex-1 outline-none">
          <a href={href} className="flex items-center gap-2 text-sm">
            <Download size={14} />
            {label}
          </a>
        </DropdownMenu.Item>
        {hasAlternates && (
          <button
            type="button"
            aria-label={`More ${LABEL_BY_OS[os]} formats`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setExpanded((v) => !v);
            }}
            className="p-1 rounded hover:bg-muted"
          >
            {expanded ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
          </button>
        )}
      </div>
      {expanded &&
        alternates.map((alt) => (
          <DropdownMenu.Item asChild key={alt.href}>
            <a
              href={alt.href}
              className="flex items-center gap-2 pl-8 pr-2 py-2 rounded-md hover:bg-muted text-sm text-muted-foreground"
            >
              ↳ {alt.label}
            </a>
          </DropdownMenu.Item>
        ))}
    </>
  );
}
```

**Note:** the expand caret intentionally calls `e.stopPropagation()` / `preventDefault()` so that Radix doesn't treat the click as a menu-item selection and close the dropdown.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/web && bun run test src/components/download-button`
Expected: all tests PASS.

The content is already wrapped in `<DropdownMenu.Portal>` so it attaches to `document.body` and is discoverable by `getByRole("menuitem")` in happy-dom.

- [ ] **Step 5: Commit**

```bash
git add apps/web/src/components/download-button.tsx apps/web/src/components/download-button.test.tsx
git commit -m "feat(web): add DownloadButton split-button component"
```

---

## Task 7: `DownloadButtonServer` wrapper

**Files:**
- Create: `apps/web/src/components/download-button-server.tsx`

This thin server component is the only entry point used by Hero, CTA, and the header. It resolves request headers and the latest release, then hands structured data to the client button. Testing it end-to-end requires a full Next.js runtime, so we skip a dedicated test here — the integration is covered manually in Task 11 plus by running the dev server in Task 12.

- [ ] **Step 1: Create the server wrapper**

Create `apps/web/src/components/download-button-server.tsx`:

```tsx
import { headers } from "next/headers";
import { detectOs } from "@/lib/detect-os";
import { getLatestRelease, type LatestRelease } from "@/lib/releases";
import { DownloadButton } from "./download-button";

type Props = {
  variant: "primary" | "header";
};

export async function DownloadButtonServer({ variant }: Props) {
  const hdrs = await headers();
  const detectedOs = detectOs(hdrs);
  let release: LatestRelease | null = null;
  try {
    release = await getLatestRelease();
  } catch {
    release = null;
  }
  return <DownloadButton variant={variant} detectedOs={detectedOs} release={release} />;
}
```

- [ ] **Step 2: Verify the project still typechecks**

Run: `cd apps/web && bunx tsc --noEmit`
Expected: exits 0, no errors.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/components/download-button-server.tsx
git commit -m "feat(web): add DownloadButtonServer that resolves OS and release"
```

---

## Task 8: Integrate into `hero.tsx`

**Files:**
- Modify: `apps/web/src/components/hero.tsx`

- [ ] **Step 1: Rewrite `hero.tsx` to use the server wrapper**

Replace the entire contents of `apps/web/src/components/hero.tsx` with:

```tsx
import { DownloadButtonServer } from "./download-button-server";

export async function Hero() {
  return (
    <section className="relative overflow-hidden pt-20 pb-32 px-6 md:pt-32 md:pb-48">
      {/* Subtle gradient background */}
      <div className="absolute inset-0 -z-10">
        <div className="absolute top-20 right-0 w-96 h-96 bg-amber-500/10 rounded-full blur-3xl"></div>
        <div className="absolute bottom-0 left-0 w-96 h-96 bg-orange-500/10 rounded-full blur-3xl"></div>
      </div>

      <div className="max-w-4xl mx-auto text-center space-y-6">
        <h1 className="text-5xl md:text-7xl font-bold text-balance leading-tight">
          Reading that adapts to{" "}
          <span className="bg-gradient-to-r from-amber-500 to-orange-500 bg-clip-text text-transparent">
            you
          </span>
        </h1>

        <p className="text-lg md:text-xl text-muted-foreground text-balance max-w-2xl mx-auto leading-relaxed">
          Imagine a reading experience where books become interactive teachers. Rishi
          transforms how you engage with knowledge through natural conversation and the
          freedom to listen at your own pace.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-8">
          <DownloadButtonServer variant="primary" />
          <button className="px-8 py-3 rounded-full border border-border text-foreground hover:bg-muted transition">
            Watch Demo
          </button>
        </div>
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Typecheck**

Run: `cd apps/web && bunx tsc --noEmit`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/components/hero.tsx
git commit -m "feat(web): wire Hero 'Get Started' to DownloadButtonServer"
```

---

## Task 9: Integrate into `cta.tsx`

**Files:**
- Modify: `apps/web/src/components/cta.tsx`

- [ ] **Step 1: Rewrite `cta.tsx`**

Replace the entire contents of `apps/web/src/components/cta.tsx` with:

```tsx
import { ArrowRight } from "lucide-react";
import { DownloadButtonServer } from "./download-button-server";

export async function CTA() {
  return (
    <section className="py-20 px-6 md:py-32 bg-gradient-to-br from-amber-500/10 to-orange-500/10">
      <div className="max-w-4xl mx-auto text-center space-y-8">
        <h2 className="text-4xl md:text-5xl font-bold text-balance">
          Ready to transform your reading?
        </h2>

        <p className="text-lg text-muted-foreground text-pretty max-w-2xl mx-auto leading-relaxed">
          Rishi is available now. Download the app and start your first book today.
          Everything you need for a smarter, richer reading experience.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-4">
          <DownloadButtonServer variant="primary" />
          <button className="px-8 py-3 rounded-full border border-border text-foreground hover:bg-muted transition flex items-center gap-2 w-full sm:w-auto justify-center">
            Learn More
            <ArrowRight size={20} />
          </button>
        </div>

        <p className="text-sm text-muted-foreground pt-8">
          Available for Mac, Windows, and Linux
        </p>
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Typecheck**

Run: `cd apps/web && bunx tsc --noEmit`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add apps/web/src/components/cta.tsx
git commit -m "feat(web): wire CTA section to DownloadButtonServer"
```

---

## Task 10: Split the header into server shell + client mobile menu

The current `header.tsx` is a client component (it owns the mobile-menu open state). To embed a server component inside it, split it into:

- `header.tsx` — server component; renders logo, desktop nav links, the desktop `<DownloadButtonServer variant="header" />`, and delegates the mobile menu to the client child.
- `header-mobile-menu.tsx` — client component; owns hamburger open state and renders mobile nav links. Accepts the header download button as `children` so the server component can be embedded.

**Files:**
- Modify: `apps/web/src/components/header.tsx`
- Create: `apps/web/src/components/header-mobile-menu.tsx`

- [ ] **Step 1: Create the client mobile menu**

Create `apps/web/src/components/header-mobile-menu.tsx`:

```tsx
"use client";

import { useState, type ReactNode } from "react";
import { Menu, X } from "lucide-react";

type Props = {
  downloadButton: ReactNode;
};

export function HeaderMobileMenu({ downloadButton }: Props) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <>
      <button
        className="md:hidden"
        onClick={() => setIsOpen((v) => !v)}
        aria-label={isOpen ? "Close menu" : "Open menu"}
        aria-expanded={isOpen}
      >
        {isOpen ? <X size={24} /> : <Menu size={24} />}
      </button>

      {isOpen && (
        <div className="md:hidden border-t border-border px-6 py-4 space-y-3">
          <a
            href="#features"
            className="block text-sm text-muted-foreground hover:text-foreground transition"
          >
            Features
          </a>
          <a
            href="#howitworks"
            className="block text-sm text-muted-foreground hover:text-foreground transition"
          >
            How it Works
          </a>
          {downloadButton}
        </div>
      )}
    </>
  );
}
```

- [ ] **Step 2: Rewrite `header.tsx` as a server component**

Replace the entire contents of `apps/web/src/components/header.tsx` with:

```tsx
import { DownloadButtonServer } from "./download-button-server";
import { HeaderMobileMenu } from "./header-mobile-menu";

export async function Header() {
  return (
    <div className="w-full">
      <div className="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-amber-500 to-orange-500 flex items-center justify-center">
            <span className="text-white font-bold text-sm">R</span>
          </div>
          <span className="text-xl font-bold">Rishi</span>
        </div>

        <nav className="hidden md:flex items-center gap-8">
          <a
            href="#features"
            className="text-sm text-muted-foreground hover:text-foreground transition"
          >
            Features
          </a>
          <a
            href="#howitworks"
            className="text-sm text-muted-foreground hover:text-foreground transition"
          >
            How it Works
          </a>
          <DownloadButtonServer variant="header" />
        </nav>

        <HeaderMobileMenu downloadButton={<DownloadButtonServer variant="header" />} />
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Typecheck**

Run: `cd apps/web && bunx tsc --noEmit`
Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add apps/web/src/components/header.tsx apps/web/src/components/header-mobile-menu.tsx
git commit -m "feat(web): wire Header to DownloadButtonServer and split client menu"
```

---

## Task 11: Full test + build + manual smoke verification

**Files:** none modified.

- [ ] **Step 1: Run all tests**

Run: `cd apps/web && bun run test`
Expected: all tests PASS (parser, findAsset, detectOs, both API routes, DownloadButton component).

- [ ] **Step 2: Run the linter**

Run: `cd apps/web && bun run lint`
Expected: no errors.

- [ ] **Step 3: Production build**

Run: `cd apps/web && bun run build`
Expected: build succeeds. Server components and API routes compile.

- [ ] **Step 4: Start the dev server and manually smoke test**

Run: `cd apps/web && bun run dev`

In another terminal, exercise the endpoints:

```bash
# Replace with the dev server URL (default http://localhost:3000)
curl -I http://localhost:3000/api/download/mac
```
Expected: HTTP/1.1 302, `location` header pointing at a `rishi_<ver>_universal.dmg` URL on `github.com` releases.

```bash
curl -I "http://localhost:3000/api/download/windows?format=msi"
```
Expected: HTTP/1.1 302, `location` header pointing at a `.msi` URL.

```bash
curl -I http://localhost:3000/api/download/linux
```
Expected: HTTP/1.1 302, `location` header pointing at an `.AppImage` URL.

```bash
curl -I http://localhost:3000/api/download/mars
```
Expected: HTTP/1.1 404.

```bash
curl -s http://localhost:3000/api/latest-release | head -c 200
```
Expected: JSON starting with `{"version":"1.1.1",...}` (or whatever the latest version is).

- [ ] **Step 5: Manual browser smoke test**

1. Open `http://localhost:3000` in the browser. Verify:
   - Header has a `Download for <your-OS>` split button.
   - Hero has the same split button (replacing "Get Started").
   - CTA section has the same split button (replacing "Download Now").
   - "Watch Demo", "Learn More", and "Available for Mac, Windows, and Linux" caption are still present.
2. Click the chevron on any of them. Verify:
   - Dropdown opens with three rows (macOS, Windows, Linux), the detected OS highlighted.
   - Windows and Linux rows have expand carets; macOS does not.
   - Clicking the Windows caret reveals `MSI installer (.msi)`.
   - Clicking the Linux caret reveals `Debian package (.deb)` and `Fedora / RHEL (.rpm)`.
   - "See all releases on GitHub" is at the bottom, opens in a new tab.
3. Click the primary label of any download button. Verify the browser is redirected (via `/api/download/<os>`) to a `github.com` asset URL and begins downloading.
4. Open DevTools, set user-agent to an iPhone UA, hard-reload. Verify:
   - Hero and CTA primary buttons say `Download for Desktop` with a `Mobile coming soon` caption below.
   - Header button still appears without the caption.
   - Clicking the primary label redirects to the macOS `.dmg`.

- [ ] **Step 6: Commit any lint/format fixes if needed**

If lint or `tsc` surfaced minor issues that required fixes, commit them separately:

```bash
git add -A
git commit -m "chore(web): fix lint warnings in download CTA integration"
```

If no changes, skip this step.

---

## Self-Review

A walkthrough against the spec (`docs/superpowers/specs/2026-04-16-web-download-cta-design.md`):

- **Goals 1-5** — all three CTA placements (Hero, CTA, Header) replaced with a split button (Tasks 8, 9, 10); dropdown lets users pick another OS/format (Task 6); no hardcoded version (Task 2's `getLatestRelease`); mobile message present (Task 6's test); GitHub-fallback paths covered (Tasks 4, 6).
- **Context table (§2)** — fixture in Task 2 matches the `v1.1.1` asset names listed in the spec.
- **§3.1 placements** — Tasks 8 (Hero), 9 (CTA), 10 (Header). Watch Demo / Learn More / reassurance caption preserved.
- **§3.2 labels and icon** — covered in Task 6 test cases for `mac`, `windows`, `mobile`, and `unknown`; primary anchor `href` asserted to be `/api/download/<os>`.
- **§3.3 dropdown layout** — Task 6 tests assert: macOS has no expand caret, Windows and Linux rows do, alternate rows link to `?format=<fmt>`, "See all releases on GitHub" link renders.
- **§3.4 mobile** — primary click defaults to `/api/download/mac` (test asserts), "Mobile coming soon" caption shows on `primary`, not on `header`.
- **§3.5 error UX** — Task 6 test asserts `release=null` renders "Download from GitHub" pointing at `releases/latest`.
- **§4.1 releases.ts API surface** — Task 2 types + exports match; `RECOMMENDED` and `GITHUB_RELEASES_URL` exported.
- **§4.2 detect-os algorithm** — Task 3 test covers steps 1-4; mobile-first-UA precedence and sec-ch-ua-platform-over-UA precedence both asserted.
- **§4.3 server wrapper** — Task 7 implements `DownloadButtonServer` using `headers()` and `getLatestRelease()` with a null fallback.
- **§4.4 client button** — Task 6.
- **§4.5 API routes** — Tasks 4 and 5; `unknown os` → 404; `unknown format` → 404; fetch failure → 302 to GitHub.
- **§5 integration** — Tasks 8-10. Header split into server shell + client menu matches the "Header caveat" note in the spec.
- **§6 error matrix** — every row maps to a test: successful fetch (Task 2), fetch-fails-cache-hit (relies on `unstable_cache` — documented, not unit-tested because cache semantics are framework-level), no-cache fallback (Task 6 `release=null`), route missing-asset (Task 4 `assets: []` case), route throws (Task 4 `mockRejectedValue`), invalid os/format (Task 4 404 cases).
- **§7 testing approach** — each bullet maps to a specific test case in Tasks 2, 3, 4, 5, 6.
- **§8 out-of-scope items** — nothing in the plan attempts them.
