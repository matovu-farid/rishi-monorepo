// @ts-nocheck
// Local book scanner E2E test
// Tests mocking of scan_for_books, get_default_book_folders, and cancel_scan
// commands. Verifies that interceptors can implement custom logic to simulate
// scan progress events and validate argument handling.
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.

export {}

await __tauriCypress.waitForReady();

const tc = __tauriCypress;
const { bridge, ipc, snapshot } = tc;

async function invoke(cmd, args) {
  return window.__TAURI_INTERNALS__.invoke(cmd, args);
}

function assert(condition, message) {
  if (!condition) throw new Error('Assertion failed: ' + message);
}

bridge.clearMocks();

// ============================
// Test 1: Mock get_default_book_folders
// ============================
const mockFolders = [
  '/Users/testuser/Documents',
  '/Users/testuser/Downloads',
  '/Users/testuser/Library/Application Support/calibre',
];

bridge.mockCommand('get_default_book_folders', mockFolders);

const folders = await invoke('get_default_book_folders');
assert(Array.isArray(folders), 'get_default_book_folders should return an array');
assert(
  (folders).length === 3,
  'Should return 3 default folders, got ' + (folders).length
);
assert(
  (folders)[0] === '/Users/testuser/Documents',
  'First folder should be Documents'
);
assert(
  (folders)[2].includes('calibre'),
  'Third folder should include calibre path'
);

snapshot.take('after-get-default-folders');

// ============================
// Test 2: Mock scan_for_books with custom interceptor
// ============================
let scanMode = null;
let scanCallCount = 0;

const mockDiscoveredBooks = [
  {
    filepath: '/Users/testuser/Documents/gatsby.epub',
    filename: 'gatsby.epub',
    title: 'The Great Gatsby',
    author: 'F. Scott Fitzgerald',
    format: 'epub',
    fileSize: 524288,
    folder: '/Users/testuser/Documents',
    fileHash: 'abc123def456',
  },
  {
    filepath: '/Users/testuser/Downloads/clean-code.pdf',
    filename: 'clean-code.pdf',
    title: 'Clean Code',
    author: null,
    format: 'pdf',
    fileSize: 2097152,
    folder: '/Users/testuser/Downloads',
    fileHash: '789ghi012jkl',
  },
  {
    filepath: '/Users/testuser/Documents/moby-dick.mobi',
    filename: 'moby-dick.mobi',
    title: 'Moby Dick',
    author: 'Herman Melville',
    format: 'mobi',
    fileSize: 1048576,
    folder: '/Users/testuser/Documents',
    fileHash: 'mno345pqr678',
  },
];

bridge.interceptCommand('scan_for_books', (args) => {
  scanCallCount++;
  const typedArgs = args;
  scanMode = typedArgs?.mode ?? null;

  // Validate mode argument
  if (scanMode !== 'default' && scanMode !== 'full') {
    throw new Error('scan_for_books mode must be "default" or "full", got: ' + scanMode);
  }

  // Return the total count of discovered books
  return mockDiscoveredBooks.length;
});

// Run a default scan
const defaultScanResult = await invoke('scan_for_books', { mode: 'default' });
assert(scanCallCount === 1, 'scan_for_books should be called once');
assert(scanMode === 'default', 'Scan mode should be "default"');
assert(
  defaultScanResult === 3,
  'Default scan should return 3 books found, got ' + defaultScanResult
);

snapshot.take('after-default-scan');

// ============================
// Test 3: Run a full system scan
// ============================
const fullScanResult = await invoke('scan_for_books', { mode: 'full' });
assert(scanCallCount === 2, 'scan_for_books should be called twice now');
assert(scanMode === 'full', 'Scan mode should be "full"');
assert(
  fullScanResult === 3,
  'Full scan should return 3 books found'
);

// ============================
// Test 4: Verify invalid mode is rejected by interceptor
// ============================
let invalidModeError = false;
try {
  await invoke('scan_for_books', { mode: 'invalid_mode' });
} catch (e) {
  invalidModeError = true;
  assert(
    (e).message.includes('must be "default" or "full"'),
    'Error should explain valid modes'
  );
}
assert(invalidModeError, 'Invalid scan mode should throw an error');

// ============================
// Test 5: Mock cancel_scan
// ============================
let cancelScanCalled = false;

bridge.interceptCommand('cancel_scan', (_args) => {
  cancelScanCalled = true;
  return null;
});

await invoke('cancel_scan');
assert((cancelScanCalled) === true, 'cancel_scan should have been called');

snapshot.take('after-cancel-scan');

// ============================
// Test 6: Verify mocked data flows correctly through the pipeline
// ============================

// Mock the full pipeline: scan -> discovered books -> save_book
let savedBooks = [];

bridge.interceptCommand('save_book', (args) => {
  const typedArgs = args;
  savedBooks.push(typedArgs?.book);
  return {
    id: savedBooks.length,
    ...(typedArgs?.book ?? {}),
    version: 1,
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  };
});

// Simulate the frontend flow: for each discovered book, save it
for (const book of mockDiscoveredBooks) {
  await invoke('save_book', {
    book: {
      kind: book.format,
      cover: [],
      title: book.title ?? book.filename,
      author: book.author ?? 'Unknown',
      publisher: '',
      filepath: book.filepath,
      location: '',
      coverKind: 'image/png',
      version: 1,
      format: book.format,
      fileHash: book.fileHash,
    },
  });
}

assert(
  savedBooks.length === 3,
  'Should have saved 3 books, got ' + savedBooks.length
);
assert(
  (savedBooks[0]).title === 'The Great Gatsby',
  'First saved book should be The Great Gatsby'
);
assert(
  (savedBooks[1]).format === 'pdf',
  'Second saved book should be a pdf'
);
assert(
  (savedBooks[2]).filepath ===
    '/Users/testuser/Documents/moby-dick.mobi',
  'Third saved book filepath should match'
);

// ============================
// Test 7: Verify complete IPC log
// ============================
const allLog = ipc.log;

const folderLog = allLog.filter(
  (e) => e.command === 'get_default_book_folders'
);
assert(folderLog.length === 1, 'get_default_book_folders should appear once');
assert(folderLog[0].mocked === true, 'get_default_book_folders should be mocked');

const scanLog = allLog.filter(
  (e) => e.command === 'scan_for_books'
);
assert(
  scanLog.length === 3,
  'scan_for_books should appear 3 times (default + full + invalid), got ' +
    scanLog.length
);

const cancelLog = allLog.filter(
  (e) => e.command === 'cancel_scan'
);
assert(cancelLog.length === 1, 'cancel_scan should appear once');

const saveLog = allLog.filter(
  (e) => e.command === 'save_book'
);
assert(
  saveLog.length === 3,
  'save_book should appear 3 times (one per discovered book), got ' +
    saveLog.length
);

// All commands in this test should be mocked/intercepted
const allMocked = allLog.every((e) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

snapshot.take('local-scanner-tests-complete');
