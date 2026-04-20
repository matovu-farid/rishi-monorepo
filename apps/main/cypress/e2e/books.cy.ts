// @ts-nocheck
// Book management test with IPC mocking
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.
export {}

// Clear state from prior tests
__tauriCypress.bridge.clearMocks();
window.__tauriCypressState.ipcLog.length = 0;

const { bridge, ipc } = __tauriCypress;

// Mock book commands
bridge.mockCommand('get_books', [
  { id: 'book-1', title: 'Test Book', author: 'Test Author', format: 'epub', path: '/test.epub' }
]);

bridge.mockCommand('get_book_data', {
  title: 'Mocked Book',
  chapters: [{ title: 'Chapter 1', content: '<p>Hello</p>' }]
});

async function invoke(cmd, args) {
  return __tauriCypress.bridge.invoke(cmd, args);
}

// Call the mocked commands via the original invoke
const books = await invoke('get_books', {});
if (!Array.isArray(books) || books.length !== 1) {
  throw new Error(`Expected 1 book, got ${JSON.stringify(books)}`);
}
if (books[0].title !== 'Test Book') {
  throw new Error(`Expected 'Test Book', got '${books[0].title}'`);
}

// Verify IPC log
const log = ipc.log;
const getBooks = log.filter((e) => e.command === 'get_books');
if (getBooks.length !== 1) throw new Error(`Expected 1 get_books call, got ${getBooks.length}`);
if (!getBooks[0].mocked) throw new Error('get_books call should be mocked');

// Test interceptCommand with search_vectors
bridge.interceptCommand('search_vectors', (_args) => {
  return { results: [{ id: 'vec-1', score: 0.95 }] };
});

const searchResult = await invoke('search_vectors', { query: 'test', book_id: 'book-1', top_k: 5 });
if (!searchResult.results || searchResult.results.length !== 1) {
  throw new Error('Search results mismatch');
}

// Clean up
bridge.clearMocks();
