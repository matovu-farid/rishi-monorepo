import { describe, expect, it } from "vitest";
import { render } from "vitest-browser-react";
import { Rendition, EpubCFI } from "epubjs";
import { ReactReader } from "@/components/react-reader";
import { themes } from "./themes/themes";
import { ThemeType } from "./themes/common";
import createIReactReaderTheme from "./themes/readerThemes";
import {
  getCurrentViewParagraphs,
  getNextViewParagraphs,
  getPreviousViewParagraphs,
  getAllParagraphsForBook,
  getTotalPagesForBook,
} from "./epubwrapper";

async function getBook() {
  const response = await fetch("/test-files/test.epub");
  if (!response.ok) {
    throw new Error(`Failed to fetch file: ${response.statusText}`);
  }
  const buffer = await response.arrayBuffer();
  let rendered = false;
  let rendition: Rendition | undefined;

  await render(
    <>
      <div
        style={{ height: "100vh", position: "relative", overflow: "hidden" }}
        // style={{ width: "600px", height: "400px" }}
      >
        <ReactReader
          url={buffer}
          location={0}
          locationChanged={() => {}}
          readerStyles={createIReactReaderTheme(
            themes[ThemeType.White].readerTheme
          )}
          getRendition={async (_rendition) => {
            _rendition.on("rendered", () => {
              rendition = _rendition;
              rendered = true;
            });
          }}
        />
      </div>
    </>
  );
  await expect.poll(() => rendered, { timeout: 10000 }).toBe(true);
  expect(rendition).toBeDefined();

  return { buffer, rendition };
}

// @ts-ignore

describe("EpubWrapper", () => {
  it("should get current view paragraphs", { timeout: 20000 }, async () => {
    const { rendition } = await getBook();

    let count = 0;

    while (getCurrentViewParagraphs(rendition!).length === 0 && count < 10) {
      await rendition?.next();
      count++;
    }

    const paragraphs = getCurrentViewParagraphs(rendition!);
    expect(paragraphs.length).toBeGreaterThan(0);
  });

  it("should get next view paragraphs", { timeout: 60000 }, async () => {
    const { rendition } = await getBook();

    for (let i = 0; i < 10; i++) {
      const nextParagraphs = await getNextViewParagraphs(rendition!);
      // expect(nextParagraphs.length).toBeGreaterThan(0);
      await rendition?.next();
      // check that the current paragraphs are the same as the next paragraphs previously fetched
      const currentParagraphs = getCurrentViewParagraphs(rendition!);
      // expect(currentParagraphs.length).toBeGreaterThan(0);
      expect(currentParagraphs).toEqual(nextParagraphs);
    }
  });

  it("should get previous view paragraphs", { timeout: 90000 }, async () => {
    const { rendition } = await getBook();

    for (let i = 0; i < 10; i++) {
      const currentParagraphs = getCurrentViewParagraphs(rendition!);
      await rendition?.next();
      await new Promise((resolve) => setTimeout(resolve, 50));

      const previousParagraphs = await getPreviousViewParagraphs(rendition!);
      expect(currentParagraphs).toEqual(previousParagraphs);
    }
  });

  it("should get paragraphs for all pages", { timeout: 100000 }, async () => {
    const { rendition } = await getBook();
    const book = rendition?.book;
    expect(book).toBeDefined();
    const totalPages = await getAllParagraphsForBook(rendition!, "test");

    expect(totalPages.length).toBeGreaterThan(0);
  });
  it("should get total pages for book", { timeout: 60000 }, async () => {
    const { rendition } = await getBook();
    const totalPages = await getTotalPagesForBook(rendition!);
    expect(totalPages).toBeGreaterThan(0);
  });
});
