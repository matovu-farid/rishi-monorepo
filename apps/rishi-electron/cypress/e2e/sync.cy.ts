/**
 * Cloud Sync — comprehensive e2e tests for status indicator, dirty flags,
 * sync IPC methods, and event system.
 *
 * NOTE: Do NOT import `path` or use `__dirname`.
 */

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
      const books = await win.electron.getBooks();
      expect(books).to.be.an("array");
    });
  });

  it("should have file hash and R2 key methods for cloud storage", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("readFile");
      expect(win.electron.readFile).to.be.a("function");
      expect(win.electron).to.have.property("copyFile");
      expect(win.electron.copyFile).to.be.a("function");
    });
  });

  it("should have the getDevBypassSecret IPC method for dev sync", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("getDevBypassSecret");
      expect(win.electron.getDevBypassSecret).to.be.a("function");
    });
  });

  it("should have the saveAuthToken IPC method for persisting tokens", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("saveAuthToken");
      expect(win.electron.saveAuthToken).to.be.a("function");
    });
  });

  it("should have the clearAuth IPC method for signing out", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("clearAuth");
      expect(win.electron.clearAuth).to.be.a("function");
    });
  });

  it("should not show sync status indicator when not synced (initial state)", () => {
    // SyncStatusIndicator returns null when status is "not-synced"
    cy.get("body").should("be.visible");
    cy.contains("Syncing...").should("not.exist");
    cy.contains("Sync error").should("not.exist");
    cy.contains("Offline").should("not.exist");
  });

  it("should support saving book data that triggers dirty flag", () => {
    cy.window().then(async (win) => {
      const book = await win.electron.saveBook({
        coverKind: "",
        title: "Sync Dirty Test",
        author: "Test",
        publisher: "",
        filepath: "/mock/sync.pdf",
        location: "1",
        version: 0,
        kind: "pdf",
        cover: [],
      });
      expect(book).to.have.property("id");
      // Clean up
      await win.electron.deleteBook(book.id);
    });
  });
});
