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
