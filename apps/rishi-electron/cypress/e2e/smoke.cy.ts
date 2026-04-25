describe("Smoke Tests", () => {
  it("should load the app", () => {
    cy.visit("/");
    cy.get("body").should("be.visible");
  });

  it("should show the library view", () => {
    cy.visit("/");
    cy.contains("Add Book").should("be.visible");
    cy.contains("Import from Computer").should("be.visible");
  });

  it("should show search input", () => {
    cy.visit("/");
    cy.get('input[placeholder*="Search"]').should("be.visible");
  });

  it("should show empty state when no books", () => {
    cy.visit("/");
    cy.contains("No books yet").should("be.visible");
  });
});
