import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("EPUB Import (getBookData fix)", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  afterEach(() => {
    // Clean up any books created during this test
    cy.window().then(async (win) => {
      const books = await win.electron.getBooks();
      for (const book of books) {
        if (
          book.title?.includes("Test") ||
          book.title?.includes("test") ||
          book.filepath === EPUB_PATH
        ) {
          await win.electron.deleteBook(book.id);
        }
      }
    });
  });

  it("should extract EPUB metadata without hanging", () => {
    // This test verifies the getBookData handler responds within a
    // reasonable time, even when cover extraction times out (the fix).
    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);

      // Must return valid metadata — never hang
      expect(bookData).to.have.property("kind", "epub");
      expect(bookData).to.have.property("filepath", EPUB_PATH);
      expect(bookData).to.have.property("version");
      expect(bookData).to.have.property("id").that.is.a("string");

      // Cover may or may not extract depending on the epub and
      // whether it timed out — but the call must resolve either way
      expect(bookData).to.have.property("cover").that.is.an("array");
    });
  });

  it("should import an EPUB and display it in the library", () => {
    cy.window()
      .then(async (win) => {
        await win.electron.copyFile(EPUB_PATH, "");
        const bookData = await win.electron.getBookData(EPUB_PATH);
        const book = await win.electron.saveBook({
          coverKind: bookData.coverKind || "",
          title: bookData.title || "Test EPUB Import",
          author: bookData.author || "Test Author",
          publisher: bookData.publisher || "",
          filepath: EPUB_PATH,
          location: "1",
          version: 0,
          kind: bookData.kind || "epub",
          cover: bookData.cover || [],
        });
        return book;
      })
      .then((book) => {
        cy.visit("/");
        const title = book.title || "Test EPUB Import";
        cy.contains(title, { timeout: 10000 }).should("be.visible");
      });
  });

  it("should return correct metadata fields from getBookData", () => {
    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);

      // kind must be epub
      expect(bookData.kind).to.equal("epub");

      // title and author should be strings or null
      if (bookData.title !== null && bookData.title !== undefined) {
        expect(bookData.title).to.be.a("string");
      }
      if (bookData.author !== null && bookData.author !== undefined) {
        expect(bookData.author).to.be.a("string");
      }

      // coverKind should be null (timed out) or "image/png"
      if (bookData.coverKind !== null && bookData.coverKind !== undefined) {
        expect(bookData.coverKind).to.equal("image/png");
      }
    });
  });
});
