import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const PDF_PATH = path.join(FIXTURES_DIR, "test-book.pdf");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("Library (Home Page)", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  afterEach(() => {
    cy.window().then(async (win) => {
      const books = await win.electron.getBooks();
      for (const book of books) {
        if (
          book.title?.includes("Test") ||
          book.title?.includes("Library")
        ) {
          await win.electron.deleteBook(book.id);
        }
      }
    });
  });

  it("should load and display the library UI", () => {
    cy.get("body").should("be.visible");
    cy.contains("Add Book").should("be.visible");
    cy.contains("Import from Computer").should("be.visible");
  });

  it("should show empty state when no books are present", () => {
    cy.contains("No books yet").should("be.visible");
    cy.contains("drag and drop").should("be.visible");
  });

  it("should show search input in the library header", () => {
    cy.get('input[placeholder*="Search"]').should("be.visible");
  });

  it("should filter books by search query without crashing", () => {
    cy.get('input[placeholder*="Search"]').type("nonexistent");
    cy.get('input[placeholder*="Search"]').should("have.value", "nonexistent");
  });

  it("should display book cards with title and author after import", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Library Test Book",
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
    cy.contains("Library Test Book", { timeout: 10000 }).should("be.visible");
    cy.contains("Test Author").should("be.visible");
  });

  it("should navigate to the reader when clicking a book card", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Library Navigate Test",
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
    cy.contains("Library Navigate Test", { timeout: 10000 }).click();
    cy.url().should("include", "/books/");
  });

  it("should delete a book via right-click context menu", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Library Delete Test",
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
    cy.contains("Library Delete Test", { timeout: 10000 }).should("be.visible");
    cy.contains("Library Delete Test").rightclick();
    cy.contains("Delete").should("be.visible");
    cy.contains("Delete").click();
    cy.contains("Library Delete Test").should("not.exist");
  });

  it("should show the context menu with Delete option on right-click", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Library Context Menu Test",
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
    cy.contains("Library Context Menu Test", { timeout: 10000 }).rightclick();
    cy.contains("Delete").should("be.visible");
    // Clicking elsewhere should dismiss the menu
    cy.get("body").click();
    cy.contains("Delete").should("not.exist");
  });

  it("should filter books by title using the search field", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Library Alpha Book",
        author: "Author A",
        publisher: "",
        filepath: PDF_PATH,
        location: "1",
        version: 0,
        kind: "pdf",
        cover: pdfData.cover || [],
      });
      const epubData = await win.electron.getBookData(EPUB_PATH);
      await win.electron.saveBook({
        coverKind: epubData.coverKind || "",
        title: "Library Beta Book",
        author: "Author B",
        publisher: "",
        filepath: EPUB_PATH,
        location: "1",
        version: 0,
        kind: "epub",
        cover: epubData.cover || [],
      });
    });

    cy.visit("/");
    cy.contains("Library Alpha Book", { timeout: 10000 }).should("be.visible");
    cy.contains("Library Beta Book").should("be.visible");

    cy.get('input[placeholder*="Search"]').type("Alpha");
    cy.contains("Library Alpha Book").should("be.visible");
    cy.contains("Library Beta Book").should("not.exist");

    cy.get('input[placeholder*="Search"]').clear();
    cy.contains("Library Alpha Book").should("be.visible");
    cy.contains("Library Beta Book").should("be.visible");
  });

  it("should show the book grid with data-tour attribute", () => {
    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(PDF_PATH);
      await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: "Library Grid Test",
        author: "Test",
        publisher: "",
        filepath: PDF_PATH,
        location: "1",
        version: 0,
        kind: "pdf",
        cover: pdfData.cover || [],
      });
    });

    cy.visit("/");
    cy.get('[data-tour="book-grid"]', { timeout: 10000 }).should("be.visible");
    cy.get('[data-tour="book-grid"] > div').should("have.length.at.least", 1);
  });
});
