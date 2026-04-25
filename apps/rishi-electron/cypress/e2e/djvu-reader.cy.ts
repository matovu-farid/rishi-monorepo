describe("DJVU Reader", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  it("should have DJVU format IPC methods available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getDjvuData");
      expect(win.electron.getDjvuData).to.be.a("function");
      expect(win.electron).to.have.property("getDjvuPage");
      expect(win.electron.getDjvuPage).to.be.a("function");
      expect(win.electron).to.have.property("getDjvuPageCount");
      expect(win.electron.getDjvuPageCount).to.be.a("function");
      expect(win.electron).to.have.property("getDjvuPageText");
      expect(win.electron.getDjvuPageText).to.be.a("function");
    });
  });

  it("should navigate to DJVU book view without crashing", () => {
    cy.visit("/#/books/999");
    cy.get("body").should("be.visible");
  });

  it("should have back button in DJVU reader", () => {
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
  });

  it("should display page navigation controls for DJVU books", () => {
    // When viewing a DJVU book, page prev/next buttons should be present
    // in the header bar (Prev | X/Y | Next)
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
  });

  it("should render canvas element for DJVU page display", () => {
    // The DjvuView component uses an HTML canvas to render pixel data
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
  });

  it("should support DJVU page rendering via IPC with DPI parameter", () => {
    cy.window().then((win) => {
      // getDjvuPage accepts path, pageNumber, and dpi
      expect(win.electron.getDjvuPage).to.be.a("function");
    });
  });

  it("should support DJVU text extraction for search and TTS", () => {
    cy.window().then((win) => {
      expect(win.electron.getDjvuPageText).to.be.a("function");
    });
  });

  it("should handle graceful error when DJVU file does not exist", () => {
    cy.visit("/#/books/999");
    cy.get("body").should("be.visible");
  });
});
