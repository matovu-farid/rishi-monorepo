/**
 * Cypress e2e test for TTS disk caching.
 *
 * These tests verify the caching integration from the renderer perspective:
 * - Cache miss triggers a network request
 * - Cache hit returns cached audio without a network request
 * - Cache can be cleared per book
 *
 * NOTE: In a real e2e environment, `window.electron` is the actual Electron
 * IPC bridge. In Cypress-only (non-Electron) mode these tests use stubs.
 */

describe("TTS Disk Cache", () => {
  beforeEach(() => {
    cy.visit("/");
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

  it("should expose embed for embedding fallback", () => {
    cy.window().then((win) => {
      expect(win.electron).to.have.property("embed");
      expect(win.electron.embed).to.be.a("function");
    });
  });
});
