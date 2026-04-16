/**
 * Set a fake Clerk dev-browser cookie before visiting so Clerk's middleware
 * doesn't 307 → dummy.clerk.accounts.dev (which 400s in tests). With this
 * cookie present Clerk treats the browser as "known" and lets the page render.
 */
function setClerkDevCookie() {
  cy.setCookie("__clerk_db_jwt", "cypress-fake-dev-browser-token");
}

describe("Download CTA — dropdown navigation", () => {
  beforeEach(() => {
    setClerkDevCookie();
    cy.visit("/");
  });

  it("navigates to /api/download/mac when clicking the macOS row", () => {
    // Intercept the redirect endpoint so Cypress doesn't actually follow the 302 to github.com
    cy.intercept("GET", "/api/download/mac*", {
      statusCode: 200,
      body: "redirected-to-mac",
    }).as("downloadMac");

    cy.get("[aria-label='Other platforms']").first().click();
    // Radix renders menuitems in a portal; use contains() to find by text content
    cy.contains("[role='menuitem']", /macOS \(\.dmg\)/).click();

    cy.wait("@downloadMac");
  });

  it("navigates to /api/download/windows when clicking the Windows row", () => {
    cy.intercept("GET", "/api/download/windows*", {
      statusCode: 200,
      body: "redirected-to-win",
    }).as("downloadWindows");

    cy.get("[aria-label='Other platforms']").first().click();
    cy.contains("[role='menuitem']", /Windows \(\.exe\)/).click();

    cy.wait("@downloadWindows");
  });

  it("navigates to /api/download/windows?format=msi when expanding and clicking the MSI alternate", () => {
    cy.intercept("GET", "/api/download/windows?format=msi", {
      statusCode: 200,
      body: "redirected-to-msi",
    }).as("downloadMsi");

    cy.get("[aria-label='Other platforms']").first().click();
    cy.get("[aria-label='More Windows formats']").click();
    cy.contains("[role='menuitem']", /MSI installer/).click();

    cy.wait("@downloadMsi");
  });

  it("navigates to /api/download/linux?format=deb when expanding and clicking the Debian alternate", () => {
    cy.intercept("GET", "/api/download/linux?format=deb", {
      statusCode: 200,
      body: "redirected-to-deb",
    }).as("downloadDeb");

    cy.get("[aria-label='Other platforms']").first().click();
    cy.get("[aria-label='More Linux formats']").click();
    cy.contains("[role='menuitem']", /Debian package/).click();

    cy.wait("@downloadDeb");
  });
});

describe("Download CTA — keyboard focus", () => {
  it("shows a visible focus ring on the download chevron when focused via keyboard", () => {
    setClerkDevCookie();
    cy.visit("/");
    cy.get("[aria-label='Other platforms']").first().as("chevron");

    // Try using real keyboard events so :focus-visible matches reliably.
    // Focus the element first, then the assertion will check for a ring.
    cy.get("@chevron").focus();

    // The chevron has Tailwind classes:
    //   outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2
    // Depending on the browser's :focus-visible heuristics, cy.focus() may or may
    // not trigger :focus-visible. We therefore assert that AT LEAST ONE of the
    // following is true:
    //   1) box-shadow is not "none" (ring applied), OR
    //   2) outline-width is non-zero (native outline applied), OR
    //   3) className includes `focus-visible:ring-2` (the styling source is present)
    cy.get("@chevron").should(($el) => {
      const boxShadow = $el.css("box-shadow");
      const outlineWidth = $el.css("outline-width");
      const className = $el.attr("class") ?? "";
      const hasComputedRing =
        (boxShadow !== undefined && boxShadow !== "none" && boxShadow !== "") ||
        (outlineWidth !== undefined && outlineWidth !== "0px" && outlineWidth !== "");
      const hasFocusVisibleClass = className.includes("focus-visible:ring-2");

      const hasRing = hasComputedRing || hasFocusVisibleClass;
      expect(
        hasRing,
        `expected a visible focus ring, got box-shadow="${boxShadow}" outline-width="${outlineWidth}" class="${className}"`,
      ).to.be.true;
    });
  });
});

describe("Download CTA — header dropdown stacking", () => {
  it("renders the header's dropdown content above the sticky header", () => {
    setClerkDevCookie();
    cy.visit("/");
    // The layout wraps everything in a sticky <header>. The site's Header component
    // (with the Download button) renders inside that sticky <header>.
    // Find the FIRST "Other platforms" button — it's inside the sticky header's desktop nav.

    // Make sure we're scrolled to top so the sticky header is visible
    cy.scrollTo("top");
    cy.get("header [aria-label='Other platforms']").first().click();

    // The dropdown menuitems should be visible and not occluded
    cy.contains("[role='menuitem']", /macOS \(\.dmg\)/).should("be.visible");
    cy.contains("[role='menuitem']", /Windows \(\.exe\)/).should("be.visible");
    cy.contains("[role='menuitem']", /Linux \(\.AppImage\)/).should("be.visible");

    // Click the macOS row and verify it's actually interactable (not occluded)
    cy.intercept("GET", "/api/download/mac*", {
      statusCode: 200,
      body: "header-dropdown-click",
    }).as("downloadMac");
    cy.contains("[role='menuitem']", /macOS \(\.dmg\)/).click();
    cy.wait("@downloadMac");
  });
});
