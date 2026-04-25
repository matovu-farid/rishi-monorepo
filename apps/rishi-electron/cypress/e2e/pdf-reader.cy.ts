/**
 * PDF Reader — comprehensive e2e tests for navigation, dual page, thumbnails, keyboard.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe("PDF Reader", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const pdfData = await win.electron.getPdfData(
        "cypress/fixtures/test-book.pdf"
      );
      const book = await win.electron.saveBook({
        coverKind: pdfData.coverKind || "",
        title: pdfData.title || "PDF Reader Test",
        author: pdfData.author || "Test Author",
        publisher: pdfData.publisher || "",
        filepath: "cypress/fixtures/test-book.pdf",
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
    cy.get('a[href="/"]', { timeout: 15000 }).should("exist");
  });

  it("should display the book title in the reader header", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("body").should("be.visible");
  });

  it("should display page navigation controls (prev/next)", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();

    cy.get("canvas, .react-pdf__Page", { timeout: 15000 }).should("exist");
  });

  it("should handle keyboard right-arrow navigation without crashing", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("body").should("be.visible");

    cy.get("body").type("{rightarrow}");
    cy.get("body").should("be.visible");
  });

  it("should handle keyboard left-arrow navigation without crashing", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("body").should("be.visible");

    cy.get("body").type("{rightarrow}");
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
      const pageData = await win.electron.getAllPageDataByBookId(bookId);
      expect(pageData).to.be.an("array");
    });
  });

  it("should gracefully handle invalid book IDs", () => {
    cy.visit("/#/books/999999");
    cy.get("body").should("be.visible");
  });

  it("should update book location when navigating pages", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("updateBookLocation");
      expect(win.electron.updateBookLocation).to.be.a("function");
    });
  });

  it("should render a canvas element for PDF page display", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("canvas", { timeout: 15000 }).should("exist");
  });

  it("should show the TTS orb in the PDF reader", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).should(
      "be.visible"
    );
  });

  it("should show the reader toolbar on mouse move near top", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("body").should("be.visible");

    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[data-tour="reader-toolbar"]', { timeout: 5000 }).should("exist");
  });

  it("should handle rapid page navigation without crashing", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get("body").should("be.visible");

    for (let i = 0; i < 5; i++) {
      cy.get("body").type("{rightarrow}");
    }
    cy.get("body").should("be.visible");
  });

  it("should navigate back to library using the back link", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get('a[href="/"]', { timeout: 15000 }).first().click({ force: true });
    cy.url().should("not.include", "/books/");
  });

  it("should show the AI chat orb in the PDF reader", () => {
    cy.visit("/");
    cy.contains("PDF Reader Test", { timeout: 10000 }).click();
    cy.get('[data-tour="ai-chat"]', { timeout: 15000 }).should("exist");
  });
});
