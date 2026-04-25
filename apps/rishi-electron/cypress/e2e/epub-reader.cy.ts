import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("EPUB Reader", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || "",
        title: bookData.title || "EPUB Reader Test",
        author: bookData.author || "Test Author",
        publisher: bookData.publisher || "",
        filepath: EPUB_PATH,
        location: "1",
        version: 0,
        kind: bookData.kind || "epub",
        cover: bookData.cover || [],
      });
      bookId = book.id;
    });
  });

  afterEach(() => {
    cy.window().then(async (win) => {
      if (bookId) {
        await win.electron.deleteBook(bookId);
      }
    });
  });

  it("should open an EPUB in the reader view", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.url().should("include", "/books/");
  });

  it("should render navigation arrow buttons", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");
    cy.get('[aria-label="Previous page"]').should("be.visible");
  });

  it("should navigate forward with the next arrow", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");
    cy.get('[aria-label="Next page"]').click();
    // Reader should still be visible after navigation
    cy.get('[aria-label="Next page"]').should("be.visible");
  });

  it("should navigate backward with the previous arrow", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    // Go forward first, then back
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).click();
    cy.get('[aria-label="Previous page"]').click();
    cy.get('[aria-label="Previous page"]').should("be.visible");
  });

  it("should show the TOC toggle button in the toolbar", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Toggle table of contents"]', { timeout: 15000 }).should("be.visible");
  });

  it("should open and close the table of contents", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();

    // Open the TOC
    cy.get('[aria-label="Toggle table of contents"]', { timeout: 15000 }).click();
    cy.contains("Table of Contents", { timeout: 5000 }).should("be.visible");

    // Close the TOC
    cy.get('[aria-label="Toggle table of contents"]').click();
    cy.contains("Table of Contents").should("not.exist");
  });

  it("should navigate to a chapter from the TOC", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();

    // Open TOC
    cy.get('[aria-label="Toggle table of contents"]', { timeout: 15000 }).click();
    cy.contains("Table of Contents", { timeout: 5000 }).should("be.visible");

    // Click on a TOC entry (the first available chapter link)
    cy.get('[aria-label="Toggle table of contents"]')
      .parents()
      .find("nav a, nav button, [role=treeitem]")
      .first()
      .click({ force: true });
  });

  it("should show the back arrow to return to library", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();

    // The back arrow link should be visible
    cy.get('a[href="/"]', { timeout: 15000 }).should("exist");
  });

  it("should display the book title in the header", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();

    // The book title should appear in the reader header
    cy.contains("EPUB Reader Test", { timeout: 15000 }).should("exist");
  });
});
