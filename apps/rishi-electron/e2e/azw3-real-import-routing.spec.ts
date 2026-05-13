import { test, expect } from '@playwright/test'
import {
  AZW3_FIXTURE,
  closeApp,
  getBookKind,
  importBookViaOpenFile,
  launchApp,
  openBook
} from './helpers/electron-app'

// Regression for the AZW3 import routing bug: when a .azw3 file is imported
// through the real OS open-file pipeline (the only path users hit), the
// renderer's dispatcher used to call `getMobiData(filePath)` for every KF8
// extension. `extractMobiData` returns `{ kind: 'mobi' }`, which the importer
// persisted verbatim. The books.$id.lazy route then rendered <MobiView> for
// the AZW3 file, producing a blank iframe and a "Blocked script execution
// in 'about:srcdoc'" console error.
//
// The existing e2e tests passed because the `importBook` helper hardcoded
// `kind: 'azw3'` into the saveBook payload, completely bypassing dispatch.
// This test uses the real pipeline (main-process `open-file` → renderer
// `open-files` IPC → BookImportService.importBatch → dispatch → saveBook).
test('AZW3 .azw3 file imports with kind=azw3 (not mobi)', async () => {
  test.setTimeout(60000)
  const launched = await launchApp()
  try {
    const bookId = await importBookViaOpenFile(launched, AZW3_FIXTURE)
    const kind = await getBookKind(launched.page, bookId)
    expect(kind, 'imported AZW3 must persist as kind=azw3').toBe('azw3')

    // Also assert the reader route actually mounts Azw3View (not MobiView).
    // The simplest signature: the AZW3 reader is the only one that renders a
    // chapter `<iframe src=blob:...>` (MobiView uses srcDoc).
    const bookPage = await openBook(launched.page, bookId)
    const iframe = bookPage.locator('iframe').first()
    await expect(iframe).toBeVisible({ timeout: 15000 })
    const src = await iframe.getAttribute('src')
    const srcdoc = await iframe.getAttribute('srcdoc')
    expect(src, 'Azw3View uses src=blob:; MobiView would use srcdoc').not.toBeNull()
    expect(src ?? '').toMatch(/^blob:/)
    expect(srcdoc, 'reader must not be MobiView').toBeNull()
  } finally {
    await closeApp(launched)
  }
})
