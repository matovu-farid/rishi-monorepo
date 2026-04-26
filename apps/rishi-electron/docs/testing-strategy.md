# Testing Strategy: Rishi Electron App

## Why Playwright Instead of Cypress

Cypress runs tests in its own Chromium browser, **not inside Electron**. This means:

- `window.electron` (the preload bridge) is **undefined** in Cypress
- No access to IPC handlers, native dialogs, or the filesystem
- Tests can only verify what a plain web page shows, not the actual Electron app

**Playwright** supports launching real Electron apps via `_electron.launch()`. Tests run inside the actual Electron process with full access to:

- `window.electron` IPC bridge
- The main process (database, filesystem, vector search)
- Native features (protocol handlers, safe storage)

## Test Architecture

```
e2e/
├── pdf-import.spec.ts      # Full lifecycle: import → library → reader → delete
├── screenshots/            # Auto-captured at each step for visual verification
│   ├── 01-empty-library.png
│   ├── 02-pdf-in-library.png
│   ├── 03-pdf-reader.png
│   ├── 04-pdf-page2.png
│   ├── 05-back-to-library.png
│   ├── 06-library-both-books.png
│   ├── 07-epub-reader.png
│   └── 08-empty-after-delete.png
playwright.config.ts
```

## How It Works

### 1. Launch the real Electron app

```typescript
import { _electron as electron } from "@playwright/test";

app = await electron.launch({
  args: [path.resolve(__dirname, "../out/main/index.js")],
});
page = await app.firstWindow();
```

This boots the actual built app (`out/main/index.js`), opens the BrowserWindow, and gives you a Playwright `Page` handle to the renderer.

### 2. Call IPC directly via `page.evaluate`

Since the test runs inside the real Electron renderer, `window.electron` is available:

```typescript
const bookId = await page.evaluate(async (pdfPath) => {
  const e = (window as any).electron;
  const appData = await e.getAppDataPath();
  const dest = appData + "/test.pdf";
  await e.copyFile(pdfPath, dest);
  const data = await e.getPdfData(dest);
  const book = await e.saveBook({ kind: "pdf", filepath: dest, ... });
  return book.id;
}, PDF_FIXTURE);
```

This exercises the full stack: renderer → preload → IPC → main process → SQLite/filesystem.

### 3. Take screenshots as assertions

```typescript
await page.screenshot({ path: "e2e/screenshots/03-pdf-reader.png" });
```

Screenshots serve as visual regression tests. Review them to catch UI issues that DOM assertions miss (layout shifts, missing styles, broken images).

### 4. Assert real behavior

```typescript
// PDF actually renders (canvas exists with content)
const canvasCount = await page.locator("canvas").count();
expect(canvasCount).toBeGreaterThan(0);

// Page count is real (not 1/0)
const pageText = await page.locator("text=/\\d+ \\/ \\d+/").textContent();
expect(pageText).not.toContain("/ 0");
```

## Running Tests

```bash
# Build first (tests run against the built app, not dev server)
pnpm run build

# Run all E2E tests
npx playwright test

# Run with headed mode (see the app)
npx playwright test --headed

# Run a specific test
npx playwright test e2e/pdf-import.spec.ts
```

## Test Fixtures

Test books live in `cypress/fixtures/` (gitignored). To set up:

```bash
cp ~/Downloads/some-book.pdf cypress/fixtures/test-book.pdf
cp ~/Downloads/some-book.epub cypress/fixtures/test-book.epub
```

## What Each Test Verifies

| Test | What it proves |
|------|----------------|
| 01 - empty library | App launches, renderer loads, preload bridge works |
| 02 - import PDF | `copyFile` IPC, `getPdfData` metadata extraction, `saveBook` DB insert, book appears in grid |
| 03 - open PDF | `readFile` IPC returns valid ArrayBuffer, pdf.js renders to canvas, page count is correct |
| 04 - navigate pages | Page state management works, re-render on page change |
| 05 - back to library | Hash routing works, library re-renders with book still present |
| 06 - import EPUB | Same IPC chain for EPUB format, both books coexist in library |
| 07 - open EPUB | epub.js parses ArrayBuffer, ReactReader renders book content |
| 08 - delete and verify | `deleteBook` soft-delete works, library returns to empty state |

## Unit Tests (Vitest)

Unit tests still use Vitest with a mocked `window.electron`:

```bash
pnpm run test        # Run unit tests
pnpm run test:watch  # Watch mode
```

The mock is defined in `src/renderer/src/test-setup.ts` and provides stub implementations of every IPC method. Unit tests verify store logic, module behavior, and component rendering without Electron.

## Adding New Tests

For a new feature, add a test that:

1. Sets up data via `page.evaluate` + `window.electron` IPC
2. Navigates to the feature
3. Takes a screenshot
4. Asserts visible DOM state
5. Cleans up test data

```typescript
test("my feature works", async () => {
  // Setup
  await page.evaluate(async () => {
    await (window as any).electron.someIpcCall();
  });

  // Navigate
  await page.evaluate(() => { window.location.hash = "#/my-route"; });
  await page.waitForTimeout(2000);

  // Verify
  await page.screenshot({ path: "e2e/screenshots/my-feature.png" });
  await expect(page.locator("text=Expected Content")).toBeVisible();

  // Cleanup
  await page.evaluate(async () => { /* undo setup */ });
});
```
