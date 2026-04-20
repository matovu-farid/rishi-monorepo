// @ts-nocheck
// Database operations E2E test
// Tests SQL command mocking: get_books, get_book, save_book, delete_book
// Verifies IPC log entries reflect correct mock status and call counts
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.

export {}

await __tauriCypress.waitForReady();

const tc = __tauriCypress;
const { bridge, ipc, snapshot } = tc;

// ---------------------------------------------------------------------------
// Helper: invoke a Tauri command through the monkey-patched invoke pathway
// ---------------------------------------------------------------------------
async function invoke(cmd, args) {
  return window.__TAURI_INTERNALS__.invoke(cmd, args);
}

function assert(condition, message) {
  if (!condition) throw new Error('Assertion failed: ' + message);
}

// ---------------------------------------------------------------------------
// Setup: clear all mocks before each logical test group
// ---------------------------------------------------------------------------
bridge.clearMocks();

// ============================
// Test 1: Mock get_books
// ============================
const mockBooks = [
  {
    id: 1,
    kind: 'epub',
    cover: [],
    title: 'The Great Gatsby',
    author: 'F. Scott Fitzgerald',
    publisher: 'Scribner',
    filepath: '/books/gatsby.epub',
    location: '',
    coverKind: 'image/png',
    version: 1,
    format: 'epub',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  },
  {
    id: 2,
    kind: 'pdf',
    cover: [],
    title: 'Clean Code',
    author: 'Robert C. Martin',
    publisher: 'Prentice Hall',
    filepath: '/books/clean-code.pdf',
    location: '',
    coverKind: 'image/jpeg',
    version: 1,
    format: 'pdf',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  },
];

bridge.mockCommand('get_books', mockBooks);

const booksResult = await invoke('get_books');
assert(Array.isArray(booksResult), 'get_books should return an array');
assert(
  (booksResult).length === 2,
  'get_books should return 2 books, got ' + (booksResult).length
);

const firstBook = (booksResult)[0];
assert(
  firstBook.title === 'The Great Gatsby',
  'First book title should be "The Great Gatsby", got "' + firstBook.title + '"'
);

// Verify IPC log for get_books
const getBooksLog = ipc.log.filter(
  (e) => e.command === 'get_books'
);
assert(getBooksLog.length === 1, 'get_books should have 1 IPC log entry');
assert(getBooksLog[0].mocked === true, 'get_books log entry should be marked as mocked');

// Take a snapshot after books load
snapshot.take('after-get-books');

// ============================
// Test 2: Mock get_book for a specific book
// ============================
const mockSingleBook = {
  id: 1,
  kind: 'epub',
  cover: [],
  title: 'The Great Gatsby',
  author: 'F. Scott Fitzgerald',
  publisher: 'Scribner',
  filepath: '/books/gatsby.epub',
  location: 'epubcfi(/6/4[chap01ref]!/4/2/2)',
  coverKind: 'image/png',
  version: 1,
  format: 'epub',
  currentCfi: 'epubcfi(/6/4[chap01ref]!/4/2/2)',
  currentPage: 42,
  syncVersion: 1,
  isDirty: 0,
  isDeleted: 0,
};

bridge.mockCommand('get_book', mockSingleBook);

const bookResult = await invoke('get_book', { bookId: 1 });
assert(bookResult !== null, 'get_book should return a book');
assert(
  (bookResult).title === 'The Great Gatsby',
  'get_book should return correct title'
);
assert(
  (bookResult).currentPage === 42,
  'get_book should return currentPage = 42'
);

// ============================
// Test 3: Mock save_book and verify it is called with correct args
// ============================
let saveBookCalledWith = null;

bridge.interceptCommand('save_book', (args) => {
  saveBookCalledWith = args;
  return {
    id: 3,
    kind: 'epub',
    cover: [],
    title: 'New Book',
    author: 'New Author',
    publisher: 'Test Publisher',
    filepath: '/books/new-book.epub',
    location: '',
    coverKind: 'image/png',
    version: 1,
    format: 'epub',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  };
});

const saveArgs = {
  book: {
    kind: 'epub',
    cover: [],
    title: 'New Book',
    author: 'New Author',
    publisher: 'Test Publisher',
    filepath: '/books/new-book.epub',
    location: '',
    coverKind: 'image/png',
    version: 1,
  },
};

const savedBook = await invoke('save_book', saveArgs);
assert(saveBookCalledWith !== null, 'save_book interceptor should have been called');
assert(
  (savedBook).id === 3,
  'save_book should return book with id 3'
);

// Verify save_book appears in IPC log as mocked (intercepted)
const saveBookLog = ipc.log.filter(
  (e) => e.command === 'save_book'
);
assert(saveBookLog.length === 1, 'save_book should have 1 IPC log entry');
assert(saveBookLog[0].mocked === true, 'save_book should be marked as mocked (intercepted)');

// ============================
// Test 4: Mock delete_book and verify call
// ============================
let deleteBookCalled = false;

bridge.interceptCommand('delete_book', (_args) => {
  deleteBookCalled = true;
  return null; // delete returns void/null
});

await invoke('delete_book', { bookId: 1 });
assert((deleteBookCalled) === true, 'delete_book interceptor should have been called');

// ============================
// Test 5: Verify total IPC log state
// ============================
const allLog = ipc.log;
const mockedEntries = allLog.filter((e) => e.mocked === true);
assert(
  mockedEntries.length >= 4,
  'Should have at least 4 mocked IPC entries (get_books, get_book, save_book, delete_book), got ' +
    mockedEntries.length
);

// ============================
// Test 6: Mock has_saved_epub_data and get_all_page_data_by_book_id
// ============================
bridge.mockCommand('has_saved_epub_data', true);
const hasSavedData = await invoke('has_saved_epub_data', { bookId: 1 });
assert(hasSavedData === true, 'has_saved_epub_data should return true');

bridge.mockCommand('get_all_page_data_by_book_id', [
  { id: 100, pageNumber: 1, bookId: 1, data: 'Chapter 1 text content' },
  { id: 101, pageNumber: 2, bookId: 1, data: 'Chapter 2 text content' },
]);
const pageData = await invoke('get_all_page_data_by_book_id', { bookId: 1 });
assert(Array.isArray(pageData), 'get_all_page_data_by_book_id should return an array');
assert(
  (pageData).length === 2,
  'Should return 2 page data entries'
);

// Final snapshot
snapshot.take('database-tests-complete');
