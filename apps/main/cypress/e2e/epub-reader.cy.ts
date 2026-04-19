// EPUB reader E2E test
// Tests the full EPUB reading flow: loading book data, page data persistence,
// reading progress tracking, and verifying all IPC interactions.
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.
import type { TauriCypressGlobal, IpcLogEntry } from 'tauri-cypress'

export {}

const tc: TauriCypressGlobal = __tauriCypress;
const { bridge, ipc, snapshot } = tc;

async function invoke(cmd: string, args?: unknown): Promise<unknown> {
  return window.__TAURI_INTERNALS__.invoke(cmd, args);
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error('Assertion failed: ' + message);
}

bridge.clearMocks();

// ============================
// Setup: realistic EPUB book data
// ============================
const mockBookData = {
  id: 'epub-gatsby-001',
  kind: 'epub',
  cover: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  title: 'The Great Gatsby',
  author: 'F. Scott Fitzgerald',
  publisher: 'Scribner',
  filepath: '/Users/testuser/Books/gatsby.epub',
  location: '',
  coverKind: 'image/png',
  version: 0,
};

const mockBookList = [
  {
    id: 1,
    kind: 'epub',
    cover: [0x89, 0x50, 0x4e, 0x47],
    title: 'The Great Gatsby',
    author: 'F. Scott Fitzgerald',
    publisher: 'Scribner',
    filepath: '/Users/testuser/Books/gatsby.epub',
    location: '',
    coverKind: 'image/png',
    version: 1,
    format: 'epub',
    currentCfi: null,
    currentPage: null,
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  },
  {
    id: 2,
    kind: 'epub',
    cover: [0x89, 0x50, 0x4e, 0x47],
    title: '1984',
    author: 'George Orwell',
    publisher: 'Secker & Warburg',
    filepath: '/Users/testuser/Books/1984.epub',
    location: 'epubcfi(/6/8!/4/2)',
    coverKind: 'image/png',
    version: 1,
    format: 'epub',
    currentCfi: 'epubcfi(/6/8!/4/2)',
    currentPage: 15,
    syncVersion: 1,
    isDirty: 0,
    isDeleted: 0,
  },
];

// ============================
// Test 1: Load EPUB book data via get_book_data
// ============================
bridge.mockCommand('get_book_data', mockBookData);

const bookData = await invoke('get_book_data', {
  path: '/Users/testuser/Books/gatsby.epub',
});

assert(bookData !== null, 'get_book_data should return book data');
const typedBookData = bookData as Record<string, unknown>;
assert(
  typedBookData.title === 'The Great Gatsby',
  'Book title should be "The Great Gatsby", got "' + typedBookData.title + '"'
);
assert(
  typedBookData.kind === 'epub',
  'Book kind should be "epub"'
);
assert(
  typedBookData.author === 'F. Scott Fitzgerald',
  'Author should be "F. Scott Fitzgerald"'
);
assert(
  typedBookData.filepath === '/Users/testuser/Books/gatsby.epub',
  'Filepath should match'
);
assert(
  Array.isArray(typedBookData.cover) && (typedBookData.cover as number[]).length === 8,
  'Cover should be a byte array with 8 PNG header bytes'
);

snapshot.take('after-get-book-data');

// ============================
// Test 2: List all books via get_books
// ============================
bridge.mockCommand('get_books', mockBookList);

const books = await invoke('get_books');
assert(Array.isArray(books), 'get_books should return an array');
assert(
  (books as unknown[]).length === 2,
  'Should return 2 books, got ' + (books as unknown[]).length
);

const firstBook = (books as Record<string, unknown>[])[0];
assert(firstBook.id === 1, 'First book id should be 1');
assert(firstBook.title === 'The Great Gatsby', 'First book should be The Great Gatsby');

const secondBook = (books as Record<string, unknown>[])[1];
assert(secondBook.currentPage === 15, 'Second book should have currentPage = 15');
assert(
  secondBook.currentCfi === 'epubcfi(/6/8!/4/2)',
  'Second book should have saved CFI location'
);

snapshot.take('after-get-books');

// ============================
// Test 3: Check for saved EPUB data (no data yet)
// ============================
bridge.mockCommand('has_saved_epub_data', false);

const hasSavedFalse = await invoke('has_saved_epub_data', { bookId: 1 });
assert(hasSavedFalse === false, 'has_saved_epub_data should return false for new book');

// Replace mock to simulate data now exists
bridge.removeMock('has_saved_epub_data');
bridge.mockCommand('has_saved_epub_data', true);

const hasSavedTrue = await invoke('has_saved_epub_data', { bookId: 1 });
assert(hasSavedTrue === true, 'has_saved_epub_data should return true after saving');

snapshot.take('after-has-saved-epub-data');

// ============================
// Test 4: Save page data via save_page_data_many
// ============================
let savedPageDataArgs: unknown = null;

bridge.interceptCommand('save_page_data_many', (args: unknown) => {
  savedPageDataArgs = args;
  return null; // returns void
});

const pageDataToSave = [
  { id: 1001, pageNumber: 1, bookId: 1, data: 'In my younger and more vulnerable years my father gave me some advice...' },
  { id: 1002, pageNumber: 2, bookId: 1, data: 'In consequence I am inclined to reserve all judgements...' },
  { id: 1003, pageNumber: 3, bookId: 1, data: 'And so with the sunshine and the great bursts of leaves growing on the trees...' },
  { id: 1004, pageNumber: 4, bookId: 1, data: 'There was music from my neighbor\'s house through the summer nights...' },
  { id: 1005, pageNumber: 5, bookId: 1, data: 'The truth was that Jay Gatsby of West Egg, Long Island, sprang from...' },
];

await invoke('save_page_data_many', { pageData: pageDataToSave });
assert(savedPageDataArgs !== null, 'save_page_data_many interceptor should have been called');
const savedArgs = savedPageDataArgs as { pageData?: unknown[] };
assert(
  Array.isArray(savedArgs.pageData) && savedArgs.pageData.length === 5,
  'Should have saved 5 page data entries'
);

snapshot.take('after-save-page-data');

// ============================
// Test 5: Retrieve page data by book ID
// ============================
const mockPageData = [
  { id: 1001, pageNumber: 1, bookId: 1, data: 'In my younger and more vulnerable years my father gave me some advice...' },
  { id: 1002, pageNumber: 2, bookId: 1, data: 'In consequence I am inclined to reserve all judgements...' },
  { id: 1003, pageNumber: 3, bookId: 1, data: 'And so with the sunshine and the great bursts of leaves growing on the trees...' },
  { id: 1004, pageNumber: 4, bookId: 1, data: 'There was music from my neighbor\'s house through the summer nights...' },
  { id: 1005, pageNumber: 5, bookId: 1, data: 'The truth was that Jay Gatsby of West Egg, Long Island, sprang from...' },
];

bridge.mockCommand('get_all_page_data_by_book_id', mockPageData);

const retrievedPageData = await invoke('get_all_page_data_by_book_id', { bookId: 1 });
assert(Array.isArray(retrievedPageData), 'get_all_page_data_by_book_id should return an array');
assert(
  (retrievedPageData as unknown[]).length === 5,
  'Should return 5 page data entries, got ' + (retrievedPageData as unknown[]).length
);

const firstPage = (retrievedPageData as Record<string, unknown>[])[0];
assert(firstPage.pageNumber === 1, 'First page number should be 1');
assert(
  (firstPage.data as string).includes('younger and more vulnerable'),
  'First page data should contain chapter 1 text'
);

const lastPage = (retrievedPageData as Record<string, unknown>[])[4];
assert(lastPage.pageNumber === 5, 'Last page number should be 5');
assert(
  (lastPage.data as string).includes('Jay Gatsby'),
  'Last page data should contain Gatsby reference'
);

snapshot.take('after-get-page-data');

// ============================
// Test 6: Update reading progress (location)
// ============================
let updateLocationArgs: unknown = null;
let updateLocationCallCount = 0;

bridge.interceptCommand('update_book_location', (args: unknown) => {
  updateLocationCallCount++;
  updateLocationArgs = args;
  return null; // returns void
});

// Simulate user navigating to chapter 3
await invoke('update_book_location', {
  bookId: 1,
  newLocation: 'epubcfi(/6/12[chap03ref]!/4/2/6)',
});

assert(updateLocationCallCount === 1, 'update_book_location should be called once');
const locationArgs = updateLocationArgs as { bookId?: number; newLocation?: string };
assert(locationArgs.bookId === 1, 'Book ID should be 1');
assert(
  locationArgs.newLocation === 'epubcfi(/6/12[chap03ref]!/4/2/6)',
  'New location should be the CFI for chapter 3'
);

// Simulate further navigation to chapter 5
await invoke('update_book_location', {
  bookId: 1,
  newLocation: 'epubcfi(/6/20[chap05ref]!/4/2/2)',
});

assert(updateLocationCallCount === 2, 'update_book_location should be called twice now');
const secondLocationArgs = updateLocationArgs as { bookId?: number; newLocation?: string };
assert(
  secondLocationArgs.newLocation === 'epubcfi(/6/20[chap05ref]!/4/2/2)',
  'Second update should have chapter 5 CFI'
);

snapshot.take('after-update-location');

// ============================
// Test 7: Verify complete IPC log
// ============================
const allLog: IpcLogEntry[] = ipc.log;

// Verify get_book_data was called
const getBookDataLog = allLog.filter((e: IpcLogEntry) => e.command === 'get_book_data');
assert(getBookDataLog.length === 1, 'get_book_data should appear once in IPC log');
assert(getBookDataLog[0].mocked === true, 'get_book_data should be mocked');

// Verify get_books was called
const getBooksLog = allLog.filter((e: IpcLogEntry) => e.command === 'get_books');
assert(getBooksLog.length === 1, 'get_books should appear once in IPC log');
assert(getBooksLog[0].mocked === true, 'get_books should be mocked');

// Verify has_saved_epub_data was called twice
const hasSavedLog = allLog.filter((e: IpcLogEntry) => e.command === 'has_saved_epub_data');
assert(
  hasSavedLog.length === 2,
  'has_saved_epub_data should appear twice in IPC log, got ' + hasSavedLog.length
);

// Verify save_page_data_many was called
const savePageLog = allLog.filter((e: IpcLogEntry) => e.command === 'save_page_data_many');
assert(savePageLog.length === 1, 'save_page_data_many should appear once');
assert(savePageLog[0].mocked === true, 'save_page_data_many should be mocked (intercepted)');

// Verify get_all_page_data_by_book_id was called
const getPageDataLog = allLog.filter(
  (e: IpcLogEntry) => e.command === 'get_all_page_data_by_book_id'
);
assert(getPageDataLog.length === 1, 'get_all_page_data_by_book_id should appear once');

// Verify update_book_location was called twice
const updateLocationLog = allLog.filter(
  (e: IpcLogEntry) => e.command === 'update_book_location'
);
assert(
  updateLocationLog.length === 2,
  'update_book_location should appear twice, got ' + updateLocationLog.length
);

// Verify all entries are mocked
const allMocked = allLog.every((e: IpcLogEntry) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

// Verify chronological ordering via timestamps
for (let i = 1; i < allLog.length; i++) {
  assert(
    allLog[i].timestamp_ms >= allLog[i - 1].timestamp_ms,
    'IPC log entries should be in chronological order'
  );
}

snapshot.take('epub-reader-tests-complete');
