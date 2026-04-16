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
