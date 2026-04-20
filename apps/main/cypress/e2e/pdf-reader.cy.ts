// @ts-nocheck
// PDF reader E2E test
// Tests the PDF reading flow: loading PDF metadata, saving/retrieving books,
// updating cover images, and verifying IPC traffic.
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
// Test 1: Load PDF metadata via get_pdf_data
// ============================
const mockPdfData = {
  id: 'pdf-clean-code-001',
  kind: 'pdf',
  cover: [0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37], // %PDF-1.7 magic bytes
  title: 'Clean Code: A Handbook of Agile Software Craftsmanship',
  author: 'Robert C. Martin',
  publisher: 'Prentice Hall',
  filepath: '/Users/testuser/Books/clean-code.pdf',
  location: '',
  coverKind: 'image/jpeg',
  version: 0,
};

bridge.mockCommand('get_pdf_data', mockPdfData);

const pdfData = await invoke('get_pdf_data', {
  path: '/Users/testuser/Books/clean-code.pdf',
});

assert(pdfData !== null, 'get_pdf_data should return book data');
const typedPdfData = pdfData;
assert(
  typedPdfData.title === 'Clean Code: A Handbook of Agile Software Craftsmanship',
  'PDF title should match, got "' + typedPdfData.title + '"'
);
assert(typedPdfData.kind === 'pdf', 'Book kind should be "pdf"');
assert(typedPdfData.author === 'Robert C. Martin', 'Author should be Robert C. Martin');
assert(
  typedPdfData.filepath === '/Users/testuser/Books/clean-code.pdf',
  'Filepath should match'
);
assert(
  Array.isArray(typedPdfData.cover) && (typedPdfData.cover).length === 8,
  'Cover should be a byte array with PDF magic bytes'
);
assert(typedPdfData.coverKind === 'image/jpeg', 'Cover kind should be image/jpeg');

snapshot.take('after-get-pdf-data');

// ============================
// Test 2: Save PDF book to database via save_book
// ============================
let saveBookArgs = null;

bridge.interceptCommand('save_book', (args) => {
  saveBookArgs = args;
  return {
    id: 10,
    kind: 'pdf',
    cover: [0x25, 0x50, 0x44, 0x46],
    title: 'Clean Code: A Handbook of Agile Software Craftsmanship',
    author: 'Robert C. Martin',
    publisher: 'Prentice Hall',
    filepath: '/Users/testuser/Books/clean-code.pdf',
    location: '',
    coverKind: 'image/jpeg',
    version: 1,
    format: 'pdf',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  };
});

const savedBook = await invoke('save_book', {
  book: {
    kind: 'pdf',
    cover: [0x25, 0x50, 0x44, 0x46],
    title: 'Clean Code: A Handbook of Agile Software Craftsmanship',
    author: 'Robert C. Martin',
    publisher: 'Prentice Hall',
    filepath: '/Users/testuser/Books/clean-code.pdf',
    location: '',
    coverKind: 'image/jpeg',
    version: 1,
    format: 'pdf',
  },
});

assert(saveBookArgs !== null, 'save_book interceptor should have been called');
const typedSavedBook = savedBook;
assert(typedSavedBook.id === 10, 'Saved book should have id 10');
assert(typedSavedBook.format === 'pdf', 'Format should be pdf');
assert(
  typedSavedBook.title === 'Clean Code: A Handbook of Agile Software Craftsmanship',
  'Title should match'
);

snapshot.take('after-save-pdf-book');

// ============================
// Test 3: Retrieve saved PDF book via get_book
// ============================
const mockRetrievedBook = {
  id: 10,
  kind: 'pdf',
  cover: [0x25, 0x50, 0x44, 0x46],
  title: 'Clean Code: A Handbook of Agile Software Craftsmanship',
  author: 'Robert C. Martin',
  publisher: 'Prentice Hall',
  filepath: '/Users/testuser/Books/clean-code.pdf',
  location: 'page:42',
  coverKind: 'image/jpeg',
  version: 1,
  format: 'pdf',
  currentCfi: null,
  currentPage: 42,
  syncVersion: 1,
  isDirty: 0,
  isDeleted: 0,
};

bridge.mockCommand('get_book', mockRetrievedBook);

const retrievedBook = await invoke('get_book', { bookId: 10 });
assert(retrievedBook !== null, 'get_book should return the PDF book');
const typedRetrievedBook = retrievedBook;
assert(typedRetrievedBook.id === 10, 'Book id should be 10');
assert(typedRetrievedBook.currentPage === 42, 'Current page should be 42');
assert(typedRetrievedBook.location === 'page:42', 'Location should be "page:42"');

snapshot.take('after-get-pdf-book');

// ============================
// Test 4: Update PDF cover image
// ============================
let updateCoverArgs = null;
let updateCoverCallCount = 0;

bridge.interceptCommand('update_book_cover', (args) => {
  updateCoverCallCount++;
  updateCoverArgs = args;
  return null; // returns void
});

// Simulate rendering first page as cover (fake PNG bytes)
const fakeCoverPng = [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG header
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
  0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0xc0, // width/height
  0x08, 0x06, 0x00, 0x00, 0x00,                     // bit depth, color type
];

await invoke('update_book_cover', {
  bookId: 10,
  newCover: fakeCoverPng,
});

assert(updateCoverCallCount === 1, 'update_book_cover should be called once');
const coverArgs = updateCoverArgs;
assert(coverArgs.bookId === 10, 'Cover update should target book 10');
const newCover = coverArgs.newCover;
assert(
  Array.isArray(newCover) && newCover.length === 29,
  'New cover should be 29 bytes, got ' + newCover.length
);
assert(
  newCover[0] === 0x89 && newCover[1] === 0x50,
  'Cover should start with PNG magic bytes'
);

snapshot.take('after-update-cover');

// ============================
// Test 5: Update reading location for PDF
// ============================
let pdfLocationArgs = null;

bridge.interceptCommand('update_book_location', (args) => {
  pdfLocationArgs = args;
  return null;
});

await invoke('update_book_location', {
  bookId: 10,
  newLocation: 'page:87',
});

assert(pdfLocationArgs !== null, 'update_book_location should have been called');
const typedLocationArgs = pdfLocationArgs;
assert(typedLocationArgs.bookId === 10, 'Should update book 10 location');
assert(typedLocationArgs.newLocation === 'page:87', 'New location should be "page:87"');

snapshot.take('after-update-pdf-location');

// ============================
// Test 6: Load a second PDF and verify independent data
// ============================
bridge.removeMock('get_pdf_data');
bridge.mockCommand('get_pdf_data', {
  id: 'pdf-design-patterns-002',
  kind: 'pdf',
  cover: [0x25, 0x50, 0x44, 0x46],
  title: 'Design Patterns: Elements of Reusable Object-Oriented Software',
  author: 'Gang of Four',
  publisher: 'Addison-Wesley',
  filepath: '/Users/testuser/Books/design-patterns.pdf',
  location: '',
  coverKind: 'image/png',
  version: 0,
});

const secondPdf = await invoke('get_pdf_data', {
  path: '/Users/testuser/Books/design-patterns.pdf',
});

assert(secondPdf !== null, 'Second PDF should load');
const typedSecondPdf = secondPdf;
assert(
  typedSecondPdf.title === 'Design Patterns: Elements of Reusable Object-Oriented Software',
  'Second PDF title should match'
);
assert(
  typedSecondPdf.id === 'pdf-design-patterns-002',
  'Second PDF should have its own ID'
);

snapshot.take('after-second-pdf');

// ============================
// Test 7: Verify complete IPC log
// ============================
const allLog = ipc.log;

// Verify get_pdf_data calls
const getPdfLog = allLog.filter((e) => e.command === 'get_pdf_data');
assert(
  getPdfLog.length === 2,
  'get_pdf_data should appear twice in IPC log (two PDFs), got ' + getPdfLog.length
);
assert(getPdfLog[0].mocked === true, 'First get_pdf_data should be mocked');
assert(getPdfLog[1].mocked === true, 'Second get_pdf_data should be mocked');

// Verify save_book was called
const saveBookLog = allLog.filter((e) => e.command === 'save_book');
assert(saveBookLog.length === 1, 'save_book should appear once');
assert(saveBookLog[0].mocked === true, 'save_book should be mocked');

// Verify get_book was called
const getBookLog = allLog.filter((e) => e.command === 'get_book');
assert(getBookLog.length === 1, 'get_book should appear once');

// Verify update_book_cover was called
const coverLog = allLog.filter((e) => e.command === 'update_book_cover');
assert(coverLog.length === 1, 'update_book_cover should appear once');

// Verify update_book_location was called
const locationLog = allLog.filter((e) => e.command === 'update_book_location');
assert(locationLog.length === 1, 'update_book_location should appear once');

// Verify all entries are mocked
const allMocked = allLog.every((e) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

// Verify correct command order
const commandOrder = allLog.map((e) => e.command);
const expectedFirst = 'get_pdf_data';
assert(
  commandOrder[0] === expectedFirst,
  'First command should be get_pdf_data, got ' + commandOrder[0]
);

snapshot.take('pdf-reader-tests-complete');
