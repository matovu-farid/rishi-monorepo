// @ts-nocheck
// Full user flow E2E test
// Tests the complete lifecycle of using the Rishi book reader:
// Import -> List -> Open -> Embed -> Search -> Read -> Delete
// Verifies the entire IPC log captures the full journey.
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
// Setup: shared constants
// ============================
const EMBED_DIM = 384;
const BOOK_ID = 1;
const EPUB_PATH = '/Users/testuser/Books/gatsby.epub';
const EXTRACT_DIR = '/Users/testuser/.rishi/extracted/gatsby';

// ============================
// Phase 1: Import a book (unzip + extract + save)
// ============================

// Step 1a: Unzip the EPUB file
let unzipArgs = null;
bridge.interceptCommand('unzip', (args) => {
  unzipArgs = args;
  const typedArgs = args;
  assert(
    typeof typedArgs?.filePath === 'string',
    'unzip requires filePath'
  );
  assert(
    typeof typedArgs?.outDir === 'string',
    'unzip requires outDir'
  );
  return EXTRACT_DIR; // PathBuf returned as string
});

const unzipResult = await invoke('unzip', {
  filePath: EPUB_PATH,
  outDir: EXTRACT_DIR,
});

assert(unzipArgs !== null, 'unzip should have been called');
assert(
  unzipResult === EXTRACT_DIR,
  'unzip should return the extraction directory'
);

snapshot.take('phase1-after-unzip');

// Step 1b: Extract book metadata
bridge.mockCommand('get_book_data', {
  id: 'epub-gatsby-001',
  kind: 'epub',
  cover: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  title: 'The Great Gatsby',
  author: 'F. Scott Fitzgerald',
  publisher: 'Scribner',
  filepath: EPUB_PATH,
  location: '',
  coverKind: 'image/png',
  version: 0,
});

const bookData = await invoke('get_book_data', { path: EPUB_PATH });
const typedBookData = bookData;
assert(typedBookData.title === 'The Great Gatsby', 'Extracted title should match');
assert(typedBookData.kind === 'epub', 'Extracted kind should be epub');

// Step 1c: Save the book to the database
let savedBookData = null;
bridge.interceptCommand('save_book', (args) => {
  savedBookData = args;
  return {
    id: BOOK_ID,
    kind: 'epub',
    cover: [0x89, 0x50, 0x4e, 0x47],
    title: 'The Great Gatsby',
    author: 'F. Scott Fitzgerald',
    publisher: 'Scribner',
    filepath: EPUB_PATH,
    location: '',
    coverKind: 'image/png',
    version: 1,
    format: 'epub',
    fileHash: 'abc123def456',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
  };
});

const savedBook = await invoke('save_book', {
  book: {
    kind: 'epub',
    cover: [0x89, 0x50, 0x4e, 0x47],
    title: 'The Great Gatsby',
    author: 'F. Scott Fitzgerald',
    publisher: 'Scribner',
    filepath: EPUB_PATH,
    location: '',
    coverKind: 'image/png',
    version: 1,
    format: 'epub',
    fileHash: 'abc123def456',
  },
});

assert(savedBookData !== null, 'save_book should have been called');
const typedSavedBook = savedBook;
assert(typedSavedBook.id === BOOK_ID, 'Saved book should have id ' + BOOK_ID);

snapshot.take('phase1-import-complete');

// ============================
// Phase 2: List books
// ============================
const mockBookList = [
  {
    id: 1,
    kind: 'epub',
    cover: [0x89, 0x50, 0x4e, 0x47],
    title: 'The Great Gatsby',
    author: 'F. Scott Fitzgerald',
    publisher: 'Scribner',
    filepath: EPUB_PATH,
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
    cover: [0x25, 0x50, 0x44, 0x46],
    title: 'Clean Code',
    author: 'Robert C. Martin',
    publisher: 'Prentice Hall',
    filepath: '/Users/testuser/Books/clean-code.pdf',
    location: 'page:42',
    coverKind: 'image/jpeg',
    version: 1,
    format: 'pdf',
    currentPage: 42,
    syncVersion: 1,
    isDirty: 0,
    isDeleted: 0,
  },
];

bridge.mockCommand('get_books', mockBookList);

const books = await invoke('get_books');
assert(Array.isArray(books), 'get_books should return an array');
assert(
  (books).length === 2,
  'Should have 2 books in library'
);

const gatsby = (books)[0];
assert(gatsby.title === 'The Great Gatsby', 'First book should be The Great Gatsby');

snapshot.take('phase2-book-list');

// ============================
// Phase 3: Open a book (retrieve + load format-specific data)
// ============================

// Step 3a: Get book details
bridge.mockCommand('get_book', {
  id: BOOK_ID,
  kind: 'epub',
  cover: [0x89, 0x50, 0x4e, 0x47],
  title: 'The Great Gatsby',
  author: 'F. Scott Fitzgerald',
  publisher: 'Scribner',
  filepath: EPUB_PATH,
  location: '',
  coverKind: 'image/png',
  version: 1,
  format: 'epub',
  currentCfi: null,
  currentPage: null,
  syncVersion: 0,
  isDirty: 0,
  isDeleted: 0,
});

const openedBook = await invoke('get_book', { bookId: BOOK_ID });
assert(openedBook !== null, 'get_book should return the book');
assert(
  (openedBook).title === 'The Great Gatsby',
  'Opened book title should match'
);

// Step 3b: Check for saved page data
bridge.mockCommand('has_saved_epub_data', false);
const hasSavedData = await invoke('has_saved_epub_data', { bookId: BOOK_ID });
assert(hasSavedData === false, 'New book should not have saved data yet');

// Step 3c: Save page data (simulate parsing EPUB content)
const pageChunks = [
  { id: 1001, pageNumber: 1, bookId: BOOK_ID, data: 'In my younger and more vulnerable years my father gave me some advice that I\'ve been turning over in my mind ever since.' },
  { id: 1002, pageNumber: 2, bookId: BOOK_ID, data: 'Whenever you feel like criticizing anyone, just remember that all the people in this world haven\'t had the advantages that you\'ve had.' },
  { id: 1003, pageNumber: 3, bookId: BOOK_ID, data: 'In consequence I\'m inclined to reserve all judgements, a habit that has opened up many curious natures to me.' },
  { id: 1004, pageNumber: 4, bookId: BOOK_ID, data: 'And so with the sunshine and the great bursts of leaves growing on the trees, just as things grow in fast movies.' },
  { id: 1005, pageNumber: 5, bookId: BOOK_ID, data: 'The abnormal mind is quick to detect and attach itself to this quality when it appears in a normal person.' },
];

bridge.interceptCommand('save_page_data_many', (_args) => {
  return null;
});

await invoke('save_page_data_many', { pageData: pageChunks });

snapshot.take('phase3-book-opened');

// ============================
// Phase 4: Generate embeddings for the book
// ============================
bridge.interceptCommand('embed', (args) => {
  const typedArgs = args;
  if (!typedArgs?.embedparams) return [];

  return typedArgs.embedparams.map((param, idx) => ({
    dim: EMBED_DIM,
    embedding: Array(EMBED_DIM).fill(0).map((_, i) => Math.sin(param.metadata.id + i + idx) * 0.1),
    text: param.text,
    metadata: param.metadata,
  }));
});

bridge.interceptCommand('save_vectors', (_args) => {
  return null;
});

// Embed the page chunks
const embedParams = pageChunks.map(chunk => ({
  text: chunk.data,
  metadata: { id: chunk.id, pageNumber: chunk.pageNumber, bookId: chunk.bookId },
}));

const embedResults = await invoke('embed', { embedparams: embedParams });
assert(Array.isArray(embedResults), 'embed should return results');
assert(
  (embedResults).length === 5,
  'Should have 5 embeddings'
);

// Save the vectors
const vectors = (embedResults).map(r => ({
  id: r.metadata.id,
  vector: r.embedding,
}));

await invoke('save_vectors', {
  name: BOOK_ID + '-vectordb',
  dim: EMBED_DIM,
  vectors: vectors,
});

snapshot.take('phase4-embeddings-generated');

// ============================
// Phase 5: Search within the book
// ============================

// Step 5a: Vector search
bridge.interceptCommand('search_vectors', (_args) => {
  return [
    { id: 1001, distance: 0.15 },
    { id: 1003, distance: 0.22 },
  ];
});

const searchResults = await invoke('search_vectors', {
  name: BOOK_ID + '-vectordb',
  query: Array(EMBED_DIM).fill(0.05),
  dim: EMBED_DIM,
  k: 2,
});

assert(
  (searchResults).length === 2,
  'Search should return 2 results'
);

// Step 5b: Retrieve text for search results
bridge.interceptCommand('get_text_from_vector_id', (args) => {
  const typedArgs = args;
  const textMap = {
    1001: pageChunks[0].data,
    1003: pageChunks[2].data,
  };
  return textMap[typedArgs?.vectorId ?? 0] || '';
});

const topResults = searchResults;
for (const result of topResults) {
  const text = await invoke('get_text_from_vector_id', { vectorId: result.id });
  assert(typeof text === 'string', 'Retrieved text should be a string');
  assert((text).length > 0, 'Retrieved text should not be empty');
}

// Step 5c: Full-text search
bridge.interceptCommand('search_book_text', (args) => {
  const typedArgs = args;
  return [
    {
      id: 1001,
      pageNumber: 1,
      bookId: typedArgs?.bookId ?? BOOK_ID,
      data: pageChunks[0].data,
      snippet: 'In my <mark>younger</mark> and more vulnerable years...',
    },
  ];
});

const ftsResults = await invoke('search_book_text', {
  query: 'younger',
  bookId: BOOK_ID,
});

assert(Array.isArray(ftsResults), 'FTS should return an array');
assert(
  (ftsResults).length === 1,
  'FTS should find 1 result'
);
const ftsFirst = (ftsResults)[0];
assert(
  ftsFirst.snippet.includes('<mark>'),
  'FTS snippet should contain highlight markup'
);

snapshot.take('phase5-search-complete');

// ============================
// Phase 6: Update reading progress
// ============================
let locationHistory = [];

bridge.interceptCommand('update_book_location', (args) => {
  const typedArgs = args;
  if (typedArgs?.newLocation) {
    locationHistory.push(typedArgs.newLocation);
  }
  return null;
});

// Simulate reading: start -> chapter 2 -> chapter 4
const progressPoints = [
  'epubcfi(/6/4[chap01ref]!/4/2/2)',
  'epubcfi(/6/8[chap02ref]!/4/2/2)',
  'epubcfi(/6/16[chap04ref]!/4/2/2)',
];

for (const cfi of progressPoints) {
  await invoke('update_book_location', {
    bookId: BOOK_ID,
    newLocation: cfi,
  });
}

assert(
  locationHistory.length === 3,
  'Should have 3 location updates, got ' + locationHistory.length
);
assert(
  locationHistory[0].includes('chap01'),
  'First update should be chapter 1'
);
assert(
  locationHistory[2].includes('chap04'),
  'Last update should be chapter 4'
);

snapshot.take('phase6-reading-progress');

// ============================
// Phase 7: Delete the book
// ============================
let deleteBookCalled = false;
let deletedBookId = null;

bridge.interceptCommand('delete_book', (args) => {
  deleteBookCalled = true;
  const typedArgs = args;
  deletedBookId = typedArgs?.bookId ?? null;
  return null; // returns void
});

await invoke('delete_book', { bookId: BOOK_ID });

assert((deleteBookCalled) === true, 'delete_book should have been called');
assert(deletedBookId === BOOK_ID, 'Should delete book with id ' + BOOK_ID);

// Verify the book is gone from the list
bridge.removeMock('get_books');
bridge.mockCommand('get_books', [mockBookList[1]]); // Only Clean Code remains

const remainingBooks = await invoke('get_books');
assert(
  (remainingBooks).length === 1,
  'Only 1 book should remain after deletion'
);
assert(
  (remainingBooks)[0].title === 'Clean Code',
  'Remaining book should be Clean Code'
);

snapshot.take('phase7-book-deleted');

// ============================
// Final: Verify the complete IPC log shows the full lifecycle
// ============================
const allLog = ipc.log;

// Count all unique command types that should appear in the lifecycle
const commandCounts = {};
for (const entry of allLog) {
  commandCounts[entry.command] = (commandCounts[entry.command] || 0) + 1;
}

// Phase 1: Import
assert(commandCounts['unzip'] === 1, 'unzip should appear once, got ' + (commandCounts['unzip'] ?? 0));
assert(commandCounts['get_book_data'] === 1, 'get_book_data should appear once');
assert(commandCounts['save_book'] === 1, 'save_book should appear once');

// Phase 2: List
assert(commandCounts['get_books'] === 2, 'get_books should appear twice (initial + after delete), got ' + (commandCounts['get_books'] ?? 0));

// Phase 3: Open
assert(commandCounts['get_book'] === 1, 'get_book should appear once');
assert(commandCounts['has_saved_epub_data'] === 1, 'has_saved_epub_data should appear once');
assert(commandCounts['save_page_data_many'] === 1, 'save_page_data_many should appear once');

// Phase 4: Embed
assert(commandCounts['embed'] === 1, 'embed should appear once');
assert(commandCounts['save_vectors'] === 1, 'save_vectors should appear once');

// Phase 5: Search
assert(commandCounts['search_vectors'] === 1, 'search_vectors should appear once');
assert(commandCounts['get_text_from_vector_id'] === 2, 'get_text_from_vector_id should appear twice');
assert(commandCounts['search_book_text'] === 1, 'search_book_text should appear once');

// Phase 6: Progress
assert(commandCounts['update_book_location'] === 3, 'update_book_location should appear 3 times');

// Phase 7: Delete
assert(commandCounts['delete_book'] === 1, 'delete_book should appear once');

// Verify all entries are mocked
const allMocked = allLog.every((e) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

// Verify chronological ordering
for (let i = 1; i < allLog.length; i++) {
  assert(
    allLog[i].timestamp_ms >= allLog[i - 1].timestamp_ms,
    'IPC log entry ' + i + ' should be chronologically after entry ' + (i - 1)
  );
}

// Verify lifecycle ordering by checking phase boundaries
const commands = allLog.map((e) => e.command);
const unzipIdx = commands.indexOf('unzip');
const getBookDataIdx = commands.indexOf('get_book_data');
const saveBookIdx = commands.indexOf('save_book');
const getBooksIdx = commands.indexOf('get_books');
const getBookIdx = commands.indexOf('get_book');
const embedIdx = commands.indexOf('embed');
const saveVecIdx = commands.indexOf('save_vectors');
const searchVecIdx = commands.indexOf('search_vectors');
const deleteIdx = commands.indexOf('delete_book');

// Import phase comes first
assert(unzipIdx < getBookDataIdx, 'unzip should come before get_book_data');
assert(getBookDataIdx < saveBookIdx, 'get_book_data should come before save_book');

// List phase comes after import
assert(saveBookIdx < getBooksIdx, 'save_book should come before get_books');

// Open phase comes after list
assert(getBooksIdx < getBookIdx, 'get_books should come before get_book');

// Embed phase comes after open
assert(getBookIdx < embedIdx, 'get_book should come before embed');
assert(embedIdx < saveVecIdx, 'embed should come before save_vectors');

// Search phase comes after embed
assert(saveVecIdx < searchVecIdx, 'save_vectors should come before search_vectors');

// Delete phase comes last
assert(searchVecIdx < deleteIdx, 'search_vectors should come before delete_book');

// Total command count should capture the full lifecycle
const totalExpected = 1 + 1 + 1 + 2 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 1 + 3 + 1; // 18
assert(
  allLog.length === totalExpected,
  'Total IPC log entries should be ' + totalExpected + ', got ' + allLog.length
);

snapshot.take('full-flow-tests-complete');
