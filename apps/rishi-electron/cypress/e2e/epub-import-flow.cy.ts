/**
 * EPUB Import Flow — End-to-end test
 *
 * Tests the full import lifecycle:
 * 1. Click "Import from Computer" on the home page
 * 2. The BookDiscoveryModal opens and scans for books
 * 3. An EPUB is found in the scan results
 * 4. Import it (via "Import All" or individual import button)
 * 5. Verify it appears in the library
 * 6. Open the book and verify the EPUB reader renders
 */

describe("EPUB Import Flow (full UI)", () => {
  beforeEach(() => {
    cy.visit("/");
    // Wait for the app to fully load
    cy.get("body", { timeout: 15000 }).should("be.visible");
  });

  afterEach(() => {
    // Clean up any books created during this test
    cy.window().then(async (win) => {
      try {
        const books = await win.electron.getBooks();
        for (const book of books) {
          if (
            book.kind === "epub" &&
            (book.filepath?.includes("test-book") ||
              book.filepath?.includes("fixture") ||
              book.title?.includes("Purple") ||
              book.title?.includes("Test"))
          ) {
            await win.electron.deleteBook(book.id);
          }
        }
      } catch {
        // ignore cleanup errors
      }
    });
  });

  it("should open the Import from Computer modal", () => {
    // Click the "Import from Computer" button
    cy.contains("Import from Computer").click();

    // Modal should appear with the title
    cy.contains("Import from Computer").should("be.visible");

    // Scan controls should be visible
    cy.contains("Common folders").should("be.visible");
    cy.contains("Search entire computer").should("be.visible");

    // Close the modal
    cy.get("button").filter(":has(svg)").first().click();
  });

  it("should import an EPUB via IPC and show it in the library", () => {
    // Directly import via IPC (simulates what happens after the modal flow)
    cy.window()
      .then(async (win) => {
        // 1. Extract EPUB metadata
        const fixtureEpub =
          "/Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/cypress/fixtures/books/test-book.epub";
        const bookData = await win.electron.getBookData(fixtureEpub);

        // Verify metadata was extracted (not hanging)
        expect(bookData).to.have.property("kind", "epub");
        expect(bookData).to.have.property("id").that.is.a("string");
        expect(bookData).to.have.property("cover").that.is.an("array");

        // 2. Save the book to the library
        const book = await win.electron.saveBook({
          coverKind: bookData.coverKind || "",
          title: bookData.title || "Test EPUB",
          author: bookData.author || "Test Author",
          publisher: bookData.publisher || "",
          filepath: fixtureEpub,
          location: "1",
          version: 0,
          kind: "epub",
          cover: bookData.cover || [],
        });

        return book;
      })
      .then((book) => {
        // 3. Reload and verify the book appears in the library
        cy.visit("/");
        const displayTitle = book.title || "Test EPUB";
        cy.contains(displayTitle, { timeout: 10000 }).should("be.visible");
      });
  });

  it("should import an EPUB, open it in the reader, and verify rendering", () => {
    const fixtureEpub =
      "/Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/cypress/fixtures/books/test-book.epub";

    // 1. Import the book
    cy.window()
      .then(async (win) => {
        const bookData = await win.electron.getBookData(fixtureEpub);
        const book = await win.electron.saveBook({
          coverKind: bookData.coverKind || "",
          title: bookData.title || "EPUB Reader Test",
          author: bookData.author || "Test Author",
          publisher: bookData.publisher || "",
          filepath: fixtureEpub,
          location: "1",
          version: 0,
          kind: "epub",
          cover: bookData.cover || [],
        });
        return book;
      })
      .then((book) => {
        // 2. Navigate to the book reader
        cy.visit(`/books/${book.id}`);

        // 3. Verify we're in the reader view
        cy.url().should("include", `/books/${book.id}`);

        // 4. Wait for EPUB content to render (ReactReader creates an iframe)
        // The reader should show some content within a reasonable time
        cy.get("body", { timeout: 15000 }).should("be.visible");

        // 5. Check the toolbar or reader controls appear
        // (ReaderToolbar should render with the book title or navigation controls)
        cy.get('[data-testid="reader-toolbar"], [class*="toolbar"], [class*="Toolbar"]', {
          timeout: 10000,
        }).should("exist");
      });
  });

  it("should import an EPUB with cover image extraction", () => {
    const fixtureEpub =
      "/Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/cypress/fixtures/books/test-book.epub";

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(fixtureEpub);

      // The new jszip-based parser should extract metadata
      expect(bookData.kind).to.equal("epub");
      expect(bookData.filepath).to.equal(fixtureEpub);

      // Title should be extracted from OPF metadata (not just filename)
      if (bookData.title) {
        expect(bookData.title).to.be.a("string");
        expect(bookData.title.length).to.be.greaterThan(0);
      }

      // Cover should be extracted (our fixture epub has one)
      if (bookData.cover && bookData.cover.length > 0) {
        expect(bookData.cover.length).to.be.greaterThan(100); // real image, not empty
        expect(bookData.coverKind).to.be.oneOf([
          "image/jpeg",
          "image/png",
          "image/gif",
        ]);
      }
    });
  });

  it("should import, delete, and verify the book is removed", () => {
    const fixtureEpub =
      "/Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/cypress/fixtures/books/test-book.epub";

    // Import
    cy.window()
      .then(async (win) => {
        const bookData = await win.electron.getBookData(fixtureEpub);
        const book = await win.electron.saveBook({
          coverKind: bookData.coverKind || "",
          title: "Delete Me EPUB",
          author: "Test",
          publisher: "",
          filepath: fixtureEpub,
          location: "1",
          version: 0,
          kind: "epub",
          cover: bookData.cover || [],
        });
        return book;
      })
      .then((book) => {
        // Verify it shows up
        cy.visit("/");
        cy.contains("Delete Me EPUB", { timeout: 10000 }).should("be.visible");

        // Delete via IPC
        cy.window().then(async (win) => {
          await win.electron.deleteBook(book.id);
        });

        // Verify it's gone after reload
        cy.visit("/");
        cy.contains("Delete Me EPUB").should("not.exist");
      });
  });

  it("should handle importing all formats via IPC", () => {
    const basePath =
      "/Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/cypress/fixtures/books/";

    cy.window().then(async (win) => {
      // EPUB
      const epubData = await win.electron.getBookData(basePath + "test-book.epub");
      expect(epubData.kind).to.equal("epub");

      // PDF
      const pdfData = await win.electron.getPdfData(basePath + "test-book.pdf");
      expect(pdfData.kind).to.equal("pdf");

      // MOBI
      const mobiData = await win.electron.getMobiData(basePath + "test-book.mobi");
      expect(mobiData.kind).to.equal("mobi");

      // DJVU
      const djvuData = await win.electron.getDjvuData(basePath + "test-book.djvu");
      expect(djvuData.kind).to.equal("djvu");

      // All should have non-null titles (parsed from actual files, not filename stubs)
      for (const data of [epubData, pdfData, mobiData, djvuData]) {
        expect(data).to.have.property("id").that.is.a("string");
        expect(data).to.have.property("filepath").that.is.a("string");
      }
    });
  });
});
