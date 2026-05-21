import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import JSZip from "jszip";
import { extractEpubCover } from "./epub-cover";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function loadFixture(name: string): Uint8Array {
  const buf = readFileSync(resolve(__dirname, "__fixtures__", name));
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}

/**
 * Build a minimal in-memory EPUB so we can exercise each cover-resolution
 * branch (meta-cover, properties=cover-image, id-contains-cover) without
 * shipping a forest of binary fixtures.
 */
async function buildEpub(opts: {
  /** OPF path inside the zip (defaults to OEBPS/content.opf). */
  opfPath?: string;
  /** OPF content -- caller assembles to control which branch is hit. */
  opfContent: string;
  /** Map of in-zip path -> bytes for cover image(s). */
  files?: Record<string, Uint8Array>;
}): Promise<Uint8Array> {
  const opfPath = opts.opfPath ?? "OEBPS/content.opf";
  const zip = new JSZip();
  zip.file(
    "META-INF/container.xml",
    `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="${opfPath}" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`
  );
  zip.file(opfPath, opts.opfContent);
  for (const [path, data] of Object.entries(opts.files ?? {})) {
    zip.file(path, data);
  }
  return zip.generateAsync({ type: "uint8array" });
}

const pngBytes = new Uint8Array([
  // 1x1 PNG header (just needs to be distinguishable bytes)
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01, 0x02, 0x03,
]);
const jpegBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]);

describe("extractEpubCover — meta cover branch", () => {
  it("resolves <meta name=\"cover\" content=\"cover-id\"/> -> manifest item", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata>
    <meta name="cover" content="cover-id"/>
  </metadata>
  <manifest>
    <item id="cover-id" href="images/cover.png" media-type="image/png"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/images/cover.png": pngBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover).not.toBeNull();
    expect(cover?.mimeType).toBe("image/png");
    expect(Array.from(cover!.data)).toEqual(Array.from(pngBytes));
  });

  it("resolves manifest items where href comes BEFORE id", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata>
    <meta name="cover" content="my-cover"/>
  </metadata>
  <manifest>
    <item href="cover.jpg" id="my-cover" media-type="image/jpeg"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/cover.jpg": jpegBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover?.mimeType).toBe("image/jpeg");
    expect(Array.from(cover!.data)).toEqual(Array.from(jpegBytes));
  });
});

describe("extractEpubCover — properties=cover-image branch (EPUB3)", () => {
  it("matches when properties comes AFTER href", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata/>
  <manifest>
    <item id="c1" href="cover3.jpeg" media-type="image/jpeg" properties="cover-image"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/cover3.jpeg": jpegBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover?.mimeType).toBe("image/jpeg");
  });

  it("matches when properties comes BEFORE href", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata/>
  <manifest>
    <item id="c1" properties="cover-image" href="cover3.gif" media-type="image/gif"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/cover3.gif": pngBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover?.mimeType).toBe("image/gif");
  });
});

describe("extractEpubCover — id contains 'cover' fallback", () => {
  it("matches manifest items with id containing 'cover' and image media-type", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata/>
  <manifest>
    <item id="cover-image-1" href="images/cover.png" media-type="image/png"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/images/cover.png": pngBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover?.mimeType).toBe("image/png");
  });

  // H3-04: Calibre and several other EPUB editors emit the manifest with
  // media-type FIRST followed by id and href. The branch-C regex only
  // searched for media-type AFTER both id and href, so these books fell
  // through all three branches and yielded `null` even though they have
  // a perfectly valid cover.
  it("matches manifest items where media-type appears BEFORE id and href", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata/>
  <manifest>
    <item media-type="image/png" id="cover-img" href="cover.png"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/cover.png": pngBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover).not.toBeNull();
    expect(cover?.mimeType).toBe("image/png");
  });
});

describe("extractEpubCover — edge cases", () => {
  it("returns null when no cover can be resolved", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata/>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
</package>`;
    const epub = await buildEpub({ opfContent: opf });

    const cover = await extractEpubCover(epub);

    expect(cover).toBeNull();
  });

  it("returns null when the cover file is referenced but missing from the zip", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata>
    <meta name="cover" content="cid"/>
  </metadata>
  <manifest>
    <item id="cid" href="missing.png" media-type="image/png"/>
  </manifest>
</package>`;
    const epub = await buildEpub({ opfContent: opf });

    const cover = await extractEpubCover(epub);

    expect(cover).toBeNull();
  });

  it("falls back gracefully when container.xml is missing", async () => {
    // Build a zip that has no container.xml. JSZip falls back to OEBPS/content.opf.
    const zip = new JSZip();
    zip.file(
      "OEBPS/content.opf",
      `<?xml version="1.0"?>
<package>
  <metadata/>
  <manifest>
    <item id="cover" href="cover.jpg" media-type="image/jpeg"/>
  </manifest>
</package>`
    );
    zip.file("OEBPS/cover.jpg", jpegBytes);
    const epub = await zip.generateAsync({ type: "uint8array" });

    const cover = await extractEpubCover(epub);

    expect(cover?.mimeType).toBe("image/jpeg");
  });

  it("returns null for a non-EPUB / invalid zip blob", async () => {
    const garbage = new Uint8Array([0x00, 0x01, 0x02, 0x03, 0x04]);

    await expect(extractEpubCover(garbage)).resolves.toBeNull();
  });

  // H3-06: some EPUB sources (e.g. Adobe-Digital-Editions-rebuilt
  // files, KF8 conversions, certain Sigil templates) emit cover hrefs
  // with `../` segments to reference a sibling directory of the OPF.
  // The existing resolver leaves the segment in place, JSZip can't
  // find the file, and the cover comes back null even though the
  // image is sitting right there in the zip.
  it("handles cover href with a parent ../ segment relative to the OPF dir", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata>
    <meta name="cover" content="cover-id"/>
  </metadata>
  <manifest>
    <item id="cover-id" href="../images/cover.png" media-type="image/png"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfPath: "OEBPS/content.opf",
      opfContent: opf,
      // The cover sits at root images/cover.png — referenced via ../
      files: { "images/cover.png": pngBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover).not.toBeNull();
    expect(cover?.mimeType).toBe("image/png");
  });

  it("handles cover href with a leading slash (absolute-style path)", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata>
    <meta name="cover" content="cid"/>
  </metadata>
  <manifest>
    <item id="cid" href="/abs/cover.png" media-type="image/png"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "abs/cover.png": pngBytes },
    });

    const cover = await extractEpubCover(epub);

    expect(cover?.mimeType).toBe("image/png");
  });
});

describe("extractEpubCover — mime-type detection", () => {
  it("detects .jpg as image/jpeg", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata><meta name="cover" content="c"/></metadata>
  <manifest>
    <item id="c" href="cover.jpg" media-type="image/jpeg"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/cover.jpg": jpegBytes },
    });
    const cover = await extractEpubCover(epub);
    expect(cover?.mimeType).toBe("image/jpeg");
  });

  it("defaults unknown extensions to image/jpeg", async () => {
    const opf = `<?xml version="1.0"?>
<package>
  <metadata><meta name="cover" content="c"/></metadata>
  <manifest>
    <item id="c" href="cover.weird" media-type="image/webp"/>
  </manifest>
</package>`;
    const epub = await buildEpub({
      opfContent: opf,
      files: { "OEBPS/cover.weird": pngBytes },
    });
    const cover = await extractEpubCover(epub);
    expect(cover?.mimeType).toBe("image/jpeg");
  });
});

describe("extractEpubCover — fixture EPUB", () => {
  it("extracts a non-null cover from the real test-book.epub fixture", async () => {
    const epub = loadFixture("test-book.epub");
    const cover = await extractEpubCover(epub);
    // Asserting only that the function works end-to-end on a real EPUB,
    // not the specific byte content (which would couple the test to the
    // fixture). The mime type is one of the standard image types.
    expect(cover).not.toBeNull();
    expect(cover!.data.length).toBeGreaterThan(0);
    expect(["image/png", "image/jpeg", "image/gif"]).toContain(cover!.mimeType);
  });
});
