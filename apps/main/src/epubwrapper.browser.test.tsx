import { describe, expect, it } from "vitest";
import { Rendition } from "epubjs";
import Book from "epubjs/types/book";
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

  // Use epubjs directly instead of going through ReactReader
  const ePub = (await import("epubjs")).default;
  const book: Book = ePub(buffer) as unknown as Book;
  await book.ready;

  const container = document.createElement("div");
  container.style.height = "100vh";
  container.style.width = "100vw";
  document.body.appendChild(container);

  const rendition: Rendition = book.renderTo(container, {
    width: "100%",
    height: "100%",
  });

  let rendered = false;
  rendition.on("rendered", () => {
    rendered = true;
  });

  await rendition.display();
  await expect.poll(() => rendered, { timeout: 10000 }).toBe(true);

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
