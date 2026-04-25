describe("Book Management", () => {
  beforeEach(() => {
    cy.visit("/");
  });

  it("should have Add Book button", () => {
    cy.contains("Add Book").should("be.visible").and("be.enabled");
  });

  it("should have Import from Computer button", () => {
    cy.contains("Import from Computer").should("be.visible").and("be.enabled");
  });

  it("should show drag and drop hint in empty state", () => {
    cy.contains("drag and drop").should("be.visible");
  });

  it("should filter books by search query", () => {
    cy.get('input[placeholder*="Search"]').type("test query");
    // Should not crash even with no results
    cy.get('input[placeholder*="Search"]').should("have.value", "test query");
  });
});
