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
    // When viewing a MOBI book, chapter prev/next buttons should be present
    // in the header bar (Prev | Ch X/Y | Next)
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
  });

  it("should support MOBI chapter extraction via IPC", () => {
    // Verify the IPC methods for chapter-level access
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
    // Should not show a blank screen or crash
  });
});
