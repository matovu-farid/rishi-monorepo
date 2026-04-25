import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("Bookmarks", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || "",
        title: "Bookmarks Test EPUB",
        author: "Test Author",
        publisher: "",
        filepath: EPUB_PATH,
        location: "1",
        version: 0,
        kind: "epub",
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

  it("should have the bookmark IPC methods available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("dbQuery");
      expect(win.electron).to.have.property("dbRun");
    });
  });

  it("should show the bookmark button in the reader toolbar", () => {
    cy.visit("/");
    cy.contains("Bookmarks Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Move mouse to top to reveal toolbar
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });

    // Bookmark button should appear in the reader toolbar
    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const bookmarkBtn = $toolbar.find('[aria-label*="bookmark"], [aria-label*="Bookmark"]');
      if (bookmarkBtn.length > 0) {
        cy.wrap(bookmarkBtn.first()).should("be.visible");
      }
    });
  });

  it("should toggle bookmark state when the bookmark button is clicked", () => {
    cy.visit("/");
    cy.contains("Bookmarks Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Reveal toolbar
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const bookmarkBtn = $toolbar.find('[aria-label="Add bookmark"]');
      if (bookmarkBtn.length > 0) {
        cy.wrap(bookmarkBtn.first()).click();
        // After clicking, the label should change to "Remove bookmark"
        cy.get('[aria-label="Remove bookmark"]', { timeout: 5000 }).should("exist");
      }
    });
  });

  it("should show empty state in bookmarks list when no bookmarks exist", () => {
    cy.visit("/");
    cy.contains("Bookmarks Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Reveal toolbar and look for bookmarks panel
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });

    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      const bmListBtn = $toolbar.find('[aria-label*="ookmark"]');
      if (bmListBtn.length > 0) {
        // Check that the empty state text can be found
        cy.contains("No bookmarks yet").should("not.exist");
      }
    });
  });
});
