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
