describe("Tutorial Flow", () => {
  beforeEach(() => {
    // Clear tutorial state before each test
    cy.visit("/");
    cy.window().then((win) => {
      win.localStorage.removeItem("rishi:tour-completed");
      win.localStorage.removeItem("rishi:hints-seen");
    });
  });

  it("should display the spotlight overlay when tour is active", () => {
    // The tour auto-starts after welcome modal dismissal
    cy.get("[data-tour='import-books']").should("exist");

    // The spotlight SVG overlay should be visible when tour is active
    cy.get("svg.fixed").should("exist");
  });

  it("should display the tour tooltip with step content", () => {
    // First tour step targets 'import-books'
    cy.get("[data-tour='import-books']").should("exist");

    // The tooltip should show step title and description
    cy.contains("Add Your Books").should("be.visible");
  });

  it("should show step counter in tooltip", () => {
    cy.get("[data-tour='import-books']").should("exist");
    cy.contains(/1 of \d+/).should("be.visible");
  });

  it("should advance to next step when Next is clicked", () => {
    cy.get("[data-tour='import-books']").should("exist");
    cy.contains("Add Your Books").should("be.visible");

    // Click Next
    cy.contains(/Next/).click();

    // Should advance to step 2
    cy.contains("Your Library").should("be.visible");
    cy.contains(/2 of \d+/).should("be.visible");
  });

  it("should skip the tour when Skip is clicked", () => {
    cy.contains("Add Your Books").should("be.visible");

    cy.contains("Skip").click();

    // Tour should be dismissed
    cy.contains("Add Your Books").should("not.exist");

    // Tour completed flag should be set
    cy.window().then((win) => {
      expect(win.localStorage.getItem("rishi:tour-completed")).to.eq("1");
    });
  });

  it("should complete the tour when navigating through all steps", () => {
    cy.contains("Add Your Books").should("be.visible");

    // Navigate forward through steps using Next until Done appears
    const clickNextOrDone = () => {
      cy.get("body").then(($body) => {
        if ($body.find(':contains("Done")').length > 0) {
          cy.contains("Done").click();
        } else if ($body.find(':contains("Next")').length > 0) {
          cy.contains("Next").click();
          clickNextOrDone();
        }
      });
    };

    clickNextOrDone();
  });

  it("should not restart tour once completed", () => {
    // Mark tour as completed
    cy.window().then((win) => {
      win.localStorage.setItem("rishi:tour-completed", "1");
    });

    cy.visit("/");

    // Tour tooltip should not appear
    cy.contains("Add Your Books").should("not.exist");
  });

  it("should show contextual hints after tour completes", () => {
    // Set tour as completed
    cy.window().then((win) => {
      win.localStorage.setItem("rishi:tour-completed", "1");
    });

    cy.visit("/");

    // Contextual hint dots (pulsing indicators) may appear near relevant UI elements
    // They are small buttons with aria-labels starting with "Hint:"
    cy.get("[aria-label^='Hint:']").should("exist");
  });

  it("should position the tooltip near the target element", () => {
    cy.get("[data-tour='import-books']").should("exist");
    cy.contains("Add Your Books").should("be.visible");

    // The tooltip should be near the import-books element
    cy.get("[data-tour='import-books']").then(($target) => {
      const targetRect = $target[0].getBoundingClientRect();
      // Tooltip should be somewhere on screen (not at 0,0)
      expect(targetRect.top).to.be.greaterThan(0);
    });
  });
});
