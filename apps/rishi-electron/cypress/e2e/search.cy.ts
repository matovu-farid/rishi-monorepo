import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("Search", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  afterEach(() => {
    cy.window().then(async (win) => {
      if (bookId) {
        await win.electron.deleteBook(bookId);
      }
    });
  });

  describe("Library search", () => {
    it("should have a search input in the library", () => {
      cy.get('input[placeholder*="Search"]').should("exist");
    });

    it("should accept text input", () => {
      cy.get('input[placeholder*="Search"]').type("Machine Learning");
      cy.get('input[placeholder*="Search"]').should("have.value", "Machine Learning");
    });

    it("should clear search", () => {
      cy.get('input[placeholder*="Search"]').type("test");
      cy.get('input[placeholder*="Search"]').clear();
      cy.get('input[placeholder*="Search"]').should("have.value", "");
    });
  });

  describe("Book text search IPC", () => {
    it("should have searchBookText IPC method available", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("searchBookText");
        expect(win.electron.searchBookText).to.be.a("function");
      });
    });

    it("should have getContextForQuery for semantic search", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("getContextForQuery");
        expect(win.electron.getContextForQuery).to.be.a("function");
      });
    });

    it("should have embed method for vector-based search", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("embed");
        expect(win.electron.embed).to.be.a("function");
      });
    });

    it("should have searchVectors method for vector queries", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("searchVectors");
        expect(win.electron.searchVectors).to.be.a("function");
      });
    });

    it("should have getTextFromVectorId for resolving vector results", () => {
      cy.window().then((win) => {
        expect(win.electron).to.have.property("getTextFromVectorId");
        expect(win.electron.getTextFromVectorId).to.be.a("function");
      });
    });
  });

  describe("In-book search panel", () => {
    beforeEach(() => {
      cy.window().then(async (win) => {
        const bookData = await win.electron.getBookData(EPUB_PATH);
        const book = await win.electron.saveBook({
          coverKind: bookData.coverKind || "",
          title: "Search Panel Test EPUB",
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

    it("should have the search panel available in the reader toolbar", () => {
      cy.visit("/");
      cy.contains("Search Panel Test EPUB", { timeout: 10000 }).click();
      cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

      // Reveal toolbar
      cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
      cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).should("exist");
    });
  });
});
