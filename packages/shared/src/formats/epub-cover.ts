import JSZip from "jszip";

/**
 * Result of a successful cover extraction.
 *
 * `mimeType` is best-guess from the cover-href extension (the OPF
 * `media-type` attribute is not consulted because some publishers lie). The
 * fallback is `image/jpeg` to match electron's behavior in
 * `apps/rishi-electron/src/main/ipc/formats.ts`.
 */
export interface EpubCover {
  mimeType: string;
  data: Uint8Array;
}

/**
 * Extract the cover image bytes from an in-memory EPUB blob.
 *
 * Returns `null` when:
 * - The blob isn't a valid zip / EPUB.
 * - The OPF cannot be located (no container.xml + no OEBPS/content.opf
 *   fallback).
 * - No cover href can be resolved from any of the three branches.
 * - The cover href IS resolved but the referenced file is missing from the
 *   zip.
 *
 * Three resolution branches, tried in order (matching electron):
 *
 * 1. EPUB2 meta-cover: `<meta name="cover" content="cover-id"/>` then look
 *    up the manifest item by id (attributes in either order).
 * 2. EPUB3 properties: manifest item with `properties="cover-image"`
 *    (attributes in either order).
 * 3. Heuristic: manifest item whose id contains "cover" with an
 *    image/* media-type (attributes in either order).
 *
 * Ported from `apps/rishi-electron/src/main/ipc/formats.ts:extractEpubData`.
 * Pure -- uses JSZip in-memory only -- so it runs unchanged on Node,
 * Electron renderer, and React Native (where node:fs is unavailable).
 *
 * @param epubBlob EPUB file bytes (typically from `expo-file-system`'s
 *   `File.bytes()` on mobile or `fs.readFile()` on Node).
 */
export async function extractEpubCover(
  epubBlob: Uint8Array,
): Promise<EpubCover | null> {
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(epubBlob);
  } catch {
    return null;
  }

  // 1. Find the OPF file path from META-INF/container.xml; fall back to
  //    the conventional OEBPS/content.opf if container is missing.
  let opfPath = "OEBPS/content.opf";
  const containerXml = await zip.file("META-INF/container.xml")?.async("text");
  if (containerXml) {
    const rootfileMatch = containerXml.match(/full-path="([^"]+)"/);
    if (rootfileMatch) opfPath = rootfileMatch[1];
  }

  const opfContent = await zip.file(opfPath)?.async("text");
  if (!opfContent) return null;

  // 2. Resolve cover href across the three branches.
  let coverHref: string | null = null;

  // Branch A: meta name="cover" content="cover-id"
  const coverMetaMatch = opfContent.match(
    /<meta\s+name="cover"\s+content="([^"]+)"/i,
  );
  const coverId = coverMetaMatch?.[1];
  if (coverId) {
    const escapedId = coverId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const idBeforeHref = new RegExp(
      `<item[^>]+id="${escapedId}"[^>]+href="([^"]+)"`,
      "i",
    );
    const hrefBeforeId = new RegExp(
      `<item[^>]+href="([^"]+)"[^>]+id="${escapedId}"`,
      "i",
    );
    const m1 = opfContent.match(idBeforeHref);
    const m2 = opfContent.match(hrefBeforeId);
    if (m1) coverHref = m1[1];
    else if (m2) coverHref = m2[1];
  }

  // Branch B: properties="cover-image" (EPUB3)
  if (!coverHref) {
    const propBeforeHref = opfContent.match(
      /<item[^>]+properties="cover-image"[^>]+href="([^"]+)"/i,
    );
    const hrefBeforeProp = opfContent.match(
      /<item[^>]+href="([^"]+)"[^>]+properties="cover-image"/i,
    );
    if (propBeforeHref) coverHref = propBeforeHref[1];
    else if (hrefBeforeProp) coverHref = hrefBeforeProp[1];
  }

  // Branch C: id contains "cover" + image media-type, attribute order
  // agnostic. The OPF spec doesn't constrain attribute order, and
  // Calibre (and several other editors) emit `media-type` before `id`
  // and `href`. Resolving in two steps -- find the <item> tag whose id
  // includes "cover" AND whose media-type is image/*, then extract the
  // href from that tag -- covers every attribute permutation. (H3-04)
  if (!coverHref) {
    const itemTagRegex = /<item\b[^>]*\/?>/gi;
    let tagMatch: RegExpExecArray | null;
    while ((tagMatch = itemTagRegex.exec(opfContent)) !== null) {
      const tag = tagMatch[0];
      const idAttr = tag.match(/\bid="([^"]*)"/i);
      const mediaAttr = tag.match(/\bmedia-type="(image\/[^"]+)"/i);
      const hrefAttr = tag.match(/\bhref="([^"]+)"/i);
      if (idAttr && /cover/i.test(idAttr[1]) && mediaAttr && hrefAttr) {
        coverHref = hrefAttr[1];
        break;
      }
    }
  }

  if (!coverHref) return null;

  // 3. Resolve href against the OPF directory and read the bytes.
  const opfDir = opfPath.includes("/")
    ? opfPath.substring(0, opfPath.lastIndexOf("/") + 1)
    : "";
  const resolvedPath = coverHref.startsWith("/")
    ? coverHref.slice(1)
    : opfDir + coverHref;
  const coverFile = zip.file(resolvedPath) ?? zip.file(coverHref);
  if (!coverFile) return null;

  const data = await coverFile.async("uint8array");

  // 4. Mime type from extension. Default to image/jpeg to match electron.
  const lowered = coverHref.toLowerCase();
  let mimeType = "image/jpeg";
  if (lowered.endsWith(".png")) mimeType = "image/png";
  else if (lowered.endsWith(".jpg") || lowered.endsWith(".jpeg"))
    mimeType = "image/jpeg";
  else if (lowered.endsWith(".gif")) mimeType = "image/gif";

  return { mimeType, data };
}
