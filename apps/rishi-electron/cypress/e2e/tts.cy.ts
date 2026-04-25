import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("Text-to-Speech Controls", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || "",
        title: "TTS Test EPUB",
        author: "Test Author",
        publisher: "",
        filepath: EPUB_PATH,
        location: "1",
        version: 0,
        kind: "epub",
        cover: bookData.cover || [],
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

  it("should show the TTS orb when a book is open", () => {
    cy.visit("/");
    cy.contains("TTS Test EPUB", { timeout: 10000 }).click();
    // The TTS orb is a fixed element with aria-label "Expand TTS controls"
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).should("be.visible");
  });

  it("should expand TTS controls when the orb is clicked", () => {
    cy.visit("/");
    cy.contains("TTS Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click();

    // After expanding, the Play, Previous, Next, and Stop buttons should appear
    cy.get('[aria-label="Play"]', { timeout: 5000 }).should("be.visible");
    cy.get('[aria-label="Previous"]').should("be.visible");
    cy.get('[aria-label="Next"]').should("be.visible");
    cy.get('[aria-label="Stop"]').should("be.visible");
  });

  it("should have Previous and Next navigation buttons", () => {
    cy.visit("/");
    cy.contains("TTS Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click();

    cy.get('[aria-label="Previous"]').should("exist");
    cy.get('[aria-label="Next"]').should("exist");
  });

  it("should disable Stop button when not playing", () => {
    cy.visit("/");
    cy.contains("TTS Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Expand TTS controls"]', { timeout: 15000 }).click();

    cy.get('[aria-label="Stop"]').should("be.disabled");
  });

  it("should have the TTS cache IPC methods available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("readDir");
      expect(win.electron).to.have.property("removeFile");
      expect(win.electron).to.have.property("getDirSize");
      expect(win.electron).to.have.property("getCacheFileStats");
      expect(win.electron).to.have.property("writeFile");
      expect(win.electron).to.have.property("readFile");
      expect(win.electron).to.have.property("exists");
      expect(win.electron).to.have.property("mkdir");
      expect(win.electron).to.have.property("getAppDataPath");
    });
  });

  it("should have the processJob IPC method available", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("processJob");
      expect(win.electron.processJob).to.be.a("function");
    });
  });
});
