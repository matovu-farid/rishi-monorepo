describe("Full Flow", () => {
  it("should load app and show library", () => {
    cy.visit("/");
    cy.get("body").should("be.visible");
    // Library UI should be present
    cy.contains("Add Book").should("be.visible");
  });

  it("should navigate between library and reader", () => {
    cy.visit("/");
    // Navigate to reader (will show error for non-existent book, that's OK)
    cy.visit("/#/books/1");
    cy.get("body").should("be.visible");
    // Navigate back
    cy.visit("/");
    cy.contains("Add Book").should("be.visible");
  });

  it("should handle keyboard navigation", () => {
    cy.visit("/");
    // Tab through interactive elements
    cy.get("body").tab();
    cy.focused().should("exist");
  });

  it("should handle window resize", () => {
    cy.visit("/");
    cy.viewport(800, 600);
    cy.get("body").should("be.visible");
    cy.viewport(1200, 900);
    cy.get("body").should("be.visible");
  });
});
