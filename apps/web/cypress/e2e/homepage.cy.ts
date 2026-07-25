export {};

function setClerkDevCookie() {
  cy.setCookie("__clerk_db_jwt", "cypress-fake-dev-browser-token");
}

describe("iOS-first homepage", () => {
  beforeEach(() => {
    setClerkDevCookie();
    cy.visit("/");
  });

  it("shows the iOS launch message and no download controls", () => {
    cy.contains("h1", "A better way to read, listen, and learn").should("be.visible");
    cy.contains(/launching soon on iphone/i).should("be.visible");
    cy.contains(/macos planned next/i).should("be.visible");
    cy.contains("Download").should("not.exist");
    cy.get('a[href="#features"]').contains("Explore the experience").should("be.visible");
  });

  it("renders the branded logo and all four iOS screenshots", () => {
    cy.get('img[src="/brand/rishi-icon.png"]').should("have.length.at.least", 2);
    for (const name of ["library", "library-books", "reader", "listening"]) {
      cy.get(`img[src="/screenshots/ios/${name}.png"]`).should("exist");
    }
  });
});
