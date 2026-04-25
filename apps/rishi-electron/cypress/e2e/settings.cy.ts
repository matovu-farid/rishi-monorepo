import path from "path";

const FIXTURES_DIR = path.resolve(__dirname, "../fixtures");
const EPUB_PATH = path.join(FIXTURES_DIR, "test-book.epub");

describe("Reader Settings", () => {
  let bookId: number;

  beforeEach(() => {
    cy.visit("/");
    cy.contains("Add Book", { timeout: 15000 }).should("be.visible");

    cy.window().then(async (win) => {
      const bookData = await win.electron.getBookData(EPUB_PATH);
      const book = await win.electron.saveBook({
        coverKind: bookData.coverKind || "",
        title: "Settings Test EPUB",
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
    cy.clearLocalStorage();
    cy.window().then(async (win) => {
      if (bookId) {
        await win.electron.deleteBook(bookId);
      }
    });
  });

  it("should show the settings button in the reader toolbar", () => {
    cy.visit("/");
    cy.contains("Settings Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Reveal toolbar
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });

    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).should("exist");
  });

  it("should open the settings popover when the settings button is clicked", () => {
    cy.visit("/");
    cy.contains("Settings Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    // Reveal toolbar and click settings
    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click();

    // Should show font size and font family controls
    cy.contains("Font Size").should("be.visible");
    cy.contains("Font Family").should("be.visible");
  });

  it("should show Serif and Sans font family options", () => {
    cy.visit("/");
    cy.contains("Settings Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click();

    cy.contains("Serif").should("be.visible");
    cy.contains("Sans").should("be.visible");
  });

  it("should have a font size slider control", () => {
    cy.visit("/");
    cy.contains("Settings Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click();

    // Should have a range input for font size
    cy.get('input[type="range"]').should("exist");
    cy.get('input[type="range"]').should("have.attr", "min", "0.8");
    cy.get('input[type="range"]').should("have.attr", "max", "2");
  });

  it("should persist font size settings in localStorage", () => {
    cy.visit("/");
    cy.contains("Settings Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click();

    // Change font size via slider
    cy.get('input[type="range"]').invoke("val", 1.5).trigger("change");

    // Verify localStorage was updated
    cy.window().then((win) => {
      const raw = win.localStorage.getItem("rishi:reader-settings");
      if (raw) {
        const settings = JSON.parse(raw);
        expect(settings).to.have.property("fontSize");
      }
    });
  });

  it("should close the settings popover when clicking outside", () => {
    cy.visit("/");
    cy.contains("Settings Test EPUB", { timeout: 10000 }).click();
    cy.get('[aria-label="Next page"]', { timeout: 15000 }).should("be.visible");

    cy.get("body").trigger("mousemove", { clientX: 500, clientY: 10 });
    cy.get('[aria-label="Reader settings"]', { timeout: 5000 }).click();
    cy.contains("Font Size").should("be.visible");

    // Click backdrop to close
    cy.get("body").click(0, 400, { force: true });
    cy.contains("Font Size").should("not.exist");
  });
});
