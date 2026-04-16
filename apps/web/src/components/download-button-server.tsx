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
