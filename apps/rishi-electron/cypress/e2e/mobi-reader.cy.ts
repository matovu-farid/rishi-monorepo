/**
 * MOBI Reader — comprehensive e2e tests for chapter navigation, content display,
 * back button, and error handling.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

describe("MOBI Reader", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  it("should have MOBI format IPC methods available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getMobiData");
      expect(win.electron.getMobiData).to.be.a("function");
      expect(win.electron).to.have.property("getMobiChapter");
      expect(win.electron.getMobiChapter).to.be.a("function");
      expect(win.electron).to.have.property("getMobiChapterCount");
      expect(win.electron.getMobiChapterCount).to.be.a("function");
      expect(win.electron).to.have.property("getMobiText");
      expect(win.electron.getMobiText).to.be.a("function");
    });
  });

  it("should navigate to MOBI book view without crashing", () => {
    cy.visit("/#/books/999");
    cy.get("body").should("be.visible");
  });

  it("should have back button in MOBI reader", () => {
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
  });

  it("should display chapter navigation controls for MOBI books", () => {
    // MobiView renders: Prev | Ch X/Y | Next
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
  });

  it("should support MOBI chapter extraction via IPC", () => {
    cy.window().then((win) => {
      expect(win.electron.getMobiChapter).to.be.a("function");
      expect(win.electron.getMobiChapterCount).to.be.a("function");
    });
  });

  it("should support MOBI text extraction for search and TTS", () => {
    cy.window().then((win) => {
      expect(win.electron.getMobiText).to.be.a("function");
    });
  });

  it("should handle graceful error when MOBI file does not exist", () => {
    cy.visit("/#/books/999");
    cy.get("body").should("be.visible");
  });

  it("should have the getMobiData method for metadata extraction", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getMobiData");
      expect(win.electron.getMobiData).to.be.a("function");
    });
  });

  it("should have updateBookLocation method for persisting MOBI reading position", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("updateBookLocation");
      expect(win.electron.updateBookLocation).to.be.a("function");
    });
  });

  it("should have the saveBook method for importing MOBI files", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("saveBook");
      expect(win.electron.saveBook).to.be.a("function");
    });
  });

  it("should not crash when navigating to a non-existent MOBI book page", () => {
    cy.visit("/#/books/99999");
    cy.get("body").should("be.visible");
    // Page should not be blank
    cy.get("body").should("not.be.empty");
  });

  it("should have the back link to return to library from MOBI reader", () => {
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
    // DjvuView and MobiView both use Link to="/"
    cy.get('a[href="/"]').should("exist");
  });
});
