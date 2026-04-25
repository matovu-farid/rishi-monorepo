import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const PDF_PATH = path.join(FIXTURES_DIR, "test-book.pdf");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("File Import", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  afterEach(() => {
    cy.window().then(async (win) => {
      const books = await win.electron.getBooks();
      for (const book of books) {
        if (
          book.title?.includes("Import") ||
          book.title?.includes("Test") ||
          book.filepath?.includes("test-book")
        ) {
          await win.electron.deleteBook(book.id);
        }
      }
    });
  });

  it("should have the Add Book button", () => {
    cy.contains("Add Book").should("be.visible").and("be.enabled");
  });

  it("should have the showOpenDialog IPC method for file picking", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("showOpenDialog");
      expect(win.electron.showOpenDialog).to.be.a("function");
    });
  });

  it("should have the checkFileSize IPC method for size validation", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("checkFileSize");
      expect(win.electron.checkFileSize).to.be.a("function");
    });
  });

  it("should validate file size and return ok for test fixtures", () => {
    cy.window().then(async (win) => {
      const result = await win.electron.checkFileSize(PDF_PATH, "pdf");
      expect(["ok", "warn"]).to.include(result);
    });
  });

  it("should extract PDF metadata via getPdfData", () => {
    cy.window().then(async (win) => {
      const data = await win.electron.getPdfData(PDF_PATH);
      expect(data).to.have.property("kind", "pdf");
      expect(data).to.have.property("filepath");
      expect(data).to.have.property("cover").that.is.an("array");
    });
  });

  it("should extract EPUB metadata via getBookData", () => {
    cy.window().then(async (win) => {
      const data = await win.electron.getBookData(EPUB_PATH);
      expect(data).to.have.property("kind", "epub");
      expect(data).to.have.property("filepath");
      expect(data).to.have.property("cover").that.is.an("array");
    });
  });

  it("should copy file to app data directory via copyFile", () => {
    cy.window().then(async (win) => {
      const appDataPath = await win.electron.getAppDataPath();
      expect(appDataPath).to.be.a("string").and.not.be.empty;

      // Copy the test PDF
      await win.electron.copyFile(PDF_PATH, appDataPath + "/import-test.pdf");
      const exists = await win.electron.exists(appDataPath + "/import-test.pdf");
      expect(exists).to.be.true;

      // Clean up
      await win.electron.removeFile(appDataPath + "/import-test.pdf");
    });
  });

  it("should save an imported book to the database", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      const book = await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Import Test Book",
        author: "Test Author",
        publisher: "",
        filepath: PDF_PATH,
        location: "1",
        version: 0,
        kind: "pdf",
        cover: pdfData.cover || [],
      });

      expect(book).to.have.property("id").that.is.a("number");
      expect(book).to.have.property("title", "Import Test Book");
      expect(book).to.have.property("kind", "pdf");
    });
  });

  it("should show the imported book in the library after save", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Import Visible Test",
        author: "Test Author",
        publisher: "",
        filepath: PDF_PATH,
        location: "1",
        version: 0,
        kind: "pdf",
        cover: pdfData.cover || [],
      });
    });

    cy.visit("/");
    cy.contains("Import Visible Test", { timeout: 10000 }).should("be.visible");
  });

  it("should support drag and drop hints in the empty library", () => {
    cy.contains("drag and drop").should("be.visible");
  });

  it("should have the getAppDataPath IPC method for determining storage location", () => {
    cy.window().then(async (win) => {
      const path = await win.electron.getAppDataPath();
      expect(path).to.be.a("string");
      expect(path.length).to.be.greaterThan(0);
    });
  });
});
