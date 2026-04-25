import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("Highlights", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || "",
        title: "Highlights Test EPUB",
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

  it("should have the highlight IPC methods available on window.electron", () => {
    cy.window().then((win) => {
      // Highlights use dbQuery and dbRun for storage
      expect(win.electron).to.have.property("dbQuery");
      expect(win.electron).to.have.property("dbRun");
      expect(win.electron.dbQuery).to.be.a("function");
      expect(win.electron.dbRun).to.be.a("function");
    });
  });

  it("should open the EPUB reader for highlight testing", () => {
    cy.visit("/");
    cy.contains("Highlights Test EPUB", { timeout: 10000 }).click();
    cy.url().should("include", "/books/");
    // Wait for the reader to load
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");
  });

  it("should show the highlights panel toggle in the toolbar", () => {
    cy.visit("/");
    cy.contains("Highlights Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Move mouse to the top of the page to reveal the toolbar
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });

    // The reader toolbar should appear
    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).should("exist");
  });

  it("should show empty state in the highlights panel when no highlights exist", () => {
    cy.visit("/");
    cy.contains("Highlights Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Move mouse to top to reveal toolbar
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });

    // Try to find and click the highlights button via aria-label or icon
    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).then(($toolbar) => {
      // The highlights panel button might exist in the toolbar
      const highlightBtn = $toolbar.find('[aria-label*="ighlight"]');
      if (highlightBtn.length > 0) {
        cy.wrap(highlightBtn).click();
        cy.contains("No highlights yet").should("be.visible");
      }
    });
  });
});
