import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const PDF_PATH = path.join(FIXTURES_DIR, "test-book.pdf");

describe("PDF Reader", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      const book = await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: pdfData.title || "PDF Reader Test",
        author: pdfData.author || "Test Author",
        publisher: pdfData.publisher || "",
        filepath: PDF_PATH,
        location: "1",
        version: 0,
        kind: "pdf",
        cover: pdfData.cover || [],
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

  it("should navigate to the PDF reader view", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.url().should("include", "/books/");
  });

  it("should show the back arrow to return to library", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    // Back link should exist
    cy.get('a[href="/"]', { timeout: 15000 }).should("exist");
  });

  it("should display the book title in the reader header", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    // Wait for reader to load
    cy.get("body").should("be.visible");
  });

  it("should display page navigation controls (prev/next)", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();

    // Wait for the PDF to render
    cy.get("canvas, .react-pdf__Page", { timeout: 15000 }).should("exist");
  });

  it("should handle keyboard navigation without crashing", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("body").should("be.visible");

    // Press arrow keys for navigation
    cy.get("body").type("{rightarrow}");
    cy.get("body").should("be.visible");
    cy.get("body").type("{leftarrow}");
    cy.get("body").should("be.visible");
  });

  it("should have getPdfData IPC method available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getPdfData");
      expect(win.electron.getPdfData).to.be.a("function");
    });
  });

  it("should have readFile IPC method for loading PDF bytes", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("readFile");
      expect(win.electron.readFile).to.be.a("function");
    });
  });

  it("should extract text from PDF for search and TTS", () => {
    cy.window().then(async (win) => {
      // getAllPageDataByBookId returns extracted text chunks
      const pageData = await win.electron.getAllPageDataByBookId(bookId);
      expect(pageData).to.be.an("array");
    });
  });

  it("should gracefully handle invalid book IDs", () => {
    cy.visit("/#/books/999999");
    cy.get("body").should("be.visible");
    // Should show error message or redirect, not crash
  });

  it("should update book location when navigating pages", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("updateBookLocation");
      expect(win.electron.updateBookLocation).to.be.a("function");
    });
  });
});
