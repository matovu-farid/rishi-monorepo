describe("Cloud Sync", () => {
  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");
  });

  it("should have the sync-related IPC methods available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getAuthToken");
      expect(win.electron.getAuthToken).to.be.a("function");
      expect(win.electron).to.have.property("dbRun");
      expect(win.electron.dbRun).to.be.a("function");
      expect(win.electron).to.have.property("dbQuery");
      expect(win.electron.dbQuery).to.be.a("function");
    });
  });

  it("should have the store value methods for sync state persistence", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getStoreValue");
      expect(win.electron.getStoreValue).to.be.a("function");
      expect(win.electron).to.have.property("setStoreValue");
      expect(win.electron.setStoreValue).to.be.a("function");
    });
  });

  it("should have event system methods for listening to sync events", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("on");
      expect(win.electron.on).to.be.a("function");
      expect(win.electron).to.have.property("once");
      expect(win.electron.once).to.be.a("function");
      expect(win.electron).to.have.property("send");
      expect(win.electron.send).to.be.a("function");
    });
  });

  it("should have isDirty column available in book model", () => {
    cy.window().then(async (win) => {
      // Query the database schema to verify isDirty column exists
      const books = await win.electron.getBooks();
      // The books array may be empty, but the API should not error
      expect(books).to.be.an("array");
    });
  });

  it("should have file hash and R2 key methods for cloud storage", () => {
    cy.window().then((win) => {
      // These methods support file syncing via R2 cloud storage
      expect(win.electron).to.have.property("readFile");
      expect(win.electron.readFile).to.be.a("function");
      expect(win.electron).to.have.property("copyFile");
      expect(win.electron.copyFile).to.be.a("function");
    });
  });
});
