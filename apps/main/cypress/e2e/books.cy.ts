// Book management test with IPC mocking
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.
export {}

const { bridge, ipc } = __tauriCypress;

// Mock book commands
bridge.mockCommand('get_books', [
  { id: 'book-1', title: 'Test Book', author: 'Test Author', format: 'epub', path: '/test.epub' }
]);

bridge.mockCommand('get_book_data', {
  title: 'Mocked Book',
  chapters: [{ title: 'Chapter 1', content: '<p>Hello</p>' }]
});

// ---------------------------------------------------------------------------
// Helper: invoke a Tauri command through the monkey-patched invoke pathway
// ---------------------------------------------------------------------------
async function invoke(cmd: string, args?: unknown): Promise<unknown> {
  return window.__TAURI_INTERNALS__.invoke(cmd, args);
}

// Call the mocked commands via the original invoke
const books = await invoke('get_books', {}) as Array<{ id: string; title: string }>;
if (!Array.isArray(books) || books.length !== 1) {
  throw new Error(`Expected 1 book, got ${JSON.stringify(books)}`);
}
if (books[0].title !== 'Test Book') {
  throw new Error(`Expected 'Test Book', got '${books[0].title}'`);
}

// Verify IPC log
const log = ipc.log;
const getBooks = log.filter(e => e.command === 'get_books');
if (getBooks.length !== 1) throw new Error(`Expected 1 get_books call, got ${getBooks.length}`);
if (!getBooks[0].mocked) throw new Error('get_books call should be mocked');

// Test interceptCommand with search_vectors
bridge.interceptCommand('search_vectors', (_args: unknown) => {
  return { results: [{ id: 'vec-1', score: 0.95 }] };
});

const searchResult = await invoke('search_vectors', { query: 'test', book_id: 'book-1', top_k: 5 }) as { results: Array<{ id: string; score: number }> };
if (!searchResult.results || searchResult.results.length !== 1) {
  throw new Error('Search results mismatch');
}

// Clean up
bridge.clearMocks();
