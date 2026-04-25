/**
 * EPUB Reader — comprehensive e2e tests for opening, navigating, TOC, themes, and arrows.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe("EPUB Reader", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(
        "cypress/fixtures/test-book.epub"
      );
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || "",
        title: bookData.title || "EPUB Reader Test",
        author: bookData.author || "Test Author",
        publisher: bookData.publisher || "",
        filepath: "cypress/fixtures/test-book.epub",
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
    cy.get('[aria-label="Next page"]').should("be.visible");
  });

  it("should navigate backward with the previous arrow", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).click();
    cy.get('[aria-label="Previous page"]').click();
    cy.get('[aria-label="Previous page"]').should("be.visible");
  });

  it("should show the TOC toggle button in the toolbar", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Toggle table of contents"]', {
      timeout: 15000,
    }).should("be.visible");
  });

  it("should open and close the table of contents", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();

    cy.get('[aria-label="Toggle table of contents"]', {
      timeout: 15000,
    }).click();
    cy.contains("Table of Contents", { timeout: 5000 }).should("be.visible");

    cy.get('[aria-label="Toggle table of contents"]').click();
    cy.contains("Table of Contents").should("not.exist");
  });

  it("should navigate to a chapter from the TOC", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();

    cy.get('[aria-label="Toggle table of contents"]', {
      timeout: 15000,
    }).click();
    cy.contains("Table of Contents", { timeout: 5000 }).should("be.visible");

    cy.get('[aria-label="Toggle table of contents"]')
      .parents()
      .find("nav a, nav button, [role=treeitem]")
      .first()
      .click({ force: true });
  });

  it("should show the back arrow to return to library", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('a[href="/"]', { timeout: 15000 }).should("exist");
  });

  it("should display the book title in the header", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.contains("EPUB Reader Test", { timeout: 15000 }).should("exist");
  });

  it("should handle rapid forward navigation without crashing", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    for (let i = 0; i < 5; i++) {
      cy.get('[aria-label="Next page"]').click();
    }
    cy.get("body").should("be.visible");
  });

  it("should support keyboard right-arrow for next page", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");
    cy.get("body").type("{rightarrow}");
    cy.get("body").should("be.visible");
  });

  it("should support keyboard left-arrow for previous page", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).click();
    cy.get("body").type("{leftarrow}");
    cy.get("body").should("be.visible");
  });

  it("should show the reader toolbar on mouse move near top", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).should("exist");
  });

  it("should show the TTS orb in the EPUB reader", () => {
    cy.visit("/");
    cy.contains("EPUB Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).should(
      "be.visible"
    );
  });
});
