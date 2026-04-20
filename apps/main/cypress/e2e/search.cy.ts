// @ts-nocheck
// Search and vector operations E2E test
// Tests IPC interception with custom validation logic for search_vectors,
// embed, get_context_for_query, and search_book_text commands.
// Demonstrates chaining multiple command mocks to simulate a complete
// search workflow.
//
// NOTE: import is stripped by the headless runner; __tauriCypress is injected
// as the function parameter by the webview's executeTestScript.

export {}

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
// Test 1: Intercept search_vectors with argument validation
// ============================
let searchVectorsCallCount = 0;
let lastSearchArgs = null;

bridge.interceptCommand('search_vectors', (args) => {
  searchVectorsCallCount++;
  lastSearchArgs = args;

  const typedArgs = args;

  // Validate required args
  if (!typedArgs || !typedArgs.name) {
    throw new Error('search_vectors requires a "name" argument');
  }
  if (!typedArgs.query || !Array.isArray(typedArgs.query)) {
    throw new Error('search_vectors requires a "query" array argument');
  }
  if (typeof typedArgs.k !== 'number' || typedArgs.k <= 0) {
    throw new Error('search_vectors requires a positive "k" argument');
  }

  // Return mock search results
  return [
    { id: 101, score: 0.95 },
    { id: 102, score: 0.87 },
    { id: 103, score: 0.72 },
  ];
});

// Call search_vectors with valid args
const searchResults = await invoke('search_vectors', {
  name: '1-vectordb',
  query: [0.1, 0.2, 0.3, 0.4, 0.5],
  dim: 5,
  k: 3,
});

assert(searchVectorsCallCount === 1, 'search_vectors should be called once');
assert(Array.isArray(searchResults), 'search_vectors should return an array');
assert(
  (searchResults).length === 3,
  'search_vectors should return 3 results'
);
assert(
  (searchResults)[0].score === 0.95,
  'First result should have score 0.95'
);

snapshot.take('after-search-vectors');

// ============================
// Test 2: Intercept embed with custom logic
// ============================
let embedCallCount = 0;

bridge.interceptCommand('embed', (args) => {
  embedCallCount++;
  const typedArgs = args;

  if (!typedArgs || !typedArgs.embedparams || typedArgs.embedparams.length === 0) {
    throw new Error('embed requires non-empty embedparams');
  }

  // Return mock embeddings: one per input text
  return typedArgs.embedparams.map(
    (param, idx) => ({
      embedding: Array(384)
        .fill(0)
        .map((_, i) => Math.sin(idx + i) * 0.1),
      metadata: param.metadata,
    })
  );
});

const embedResult = await invoke('embed', {
  embedparams: [
    { text: 'quantum mechanics', metadata: { id: 1, page_number: 1, book_id: 1 } },
    { text: 'neural networks', metadata: { id: 2, page_number: 2, book_id: 1 } },
  ],
});

assert(embedCallCount === 1, 'embed should be called once');
assert(Array.isArray(embedResult), 'embed should return an array');
assert(
  (embedResult).length === 2,
  'embed should return 2 embeddings'
);

const firstEmbedding = (embedResult)[0];
assert(
  firstEmbedding.embedding.length === 384,
  'Each embedding should have 384 dimensions'
);

snapshot.take('after-embed');

// ============================
// Test 3: Intercept search_vectors with invalid args (expect error)
// ============================
let errorCaught = false;
try {
  // Missing "name" arg should trigger validation error
  await invoke('search_vectors', {
    query: [0.1, 0.2],
    dim: 2,
    k: 5,
  });
} catch (e) {
  errorCaught = true;
  assert(
    (e).message.includes('"name"'),
    'Error should mention missing "name" argument'
  );
}
assert(errorCaught, 'search_vectors with missing name should throw an error');
assert(searchVectorsCallCount === 2, 'search_vectors should have been called twice total');

// ============================
// Test 4: Chain multiple commands to simulate a search flow
// ============================

// Step 4a: Mock save_vectors (used when indexing)
let saveVectorsCallCount = 0;
bridge.interceptCommand('save_vectors', (args) => {
  saveVectorsCallCount++;
  return null; // save_vectors returns ()
});

// Step 4b: Mock get_text_from_vector_id
bridge.interceptCommand('get_text_from_vector_id', (args) => {
  const typedArgs = args;
  const textMap = {
    101: 'The philosophy of consciousness has been debated for centuries.',
    102: 'Quantum mechanics describes the behavior of particles at atomic scales.',
    103: 'Neural networks in the brain give rise to consciousness and awareness.',
  };
  return textMap[typedArgs?.vectorId ?? 0] || '';
});

// Step 4c: Mock get_context_for_query (the full search pipeline)
bridge.interceptCommand('get_context_for_query', (args) => {
  const typedArgs = args;
  assert(
    typeof typedArgs?.queryText === 'string',
    'get_context_for_query needs queryText'
  );
  assert(
    typeof typedArgs?.bookId === 'number',
    'get_context_for_query needs bookId'
  );
  return [
    'The philosophy of consciousness has been debated for centuries.',
    'Neural networks in the brain give rise to consciousness and awareness.',
  ];
});

const contextResults = await invoke('get_context_for_query', {
  queryText: 'consciousness',
  bookId: 1,
  k: 3,
});
assert(Array.isArray(contextResults), 'get_context_for_query should return an array');
assert(
  (contextResults).length === 2,
  'Should return 2 context passages'
);
assert(
  (contextResults)[0].includes('consciousness'),
  'First context passage should mention consciousness'
);

// Step 4d: Mock search_book_text (FTS)
bridge.interceptCommand('search_book_text', (args) => {
  const typedArgs = args;
  return [
    {
      id: 1,
      pageNumber: 1,
      bookId: typedArgs?.bookId ?? 0,
      data: 'The philosophy of consciousness has been debated.',
      snippet: 'The philosophy of <mark>consciousness</mark> has been debated.',
    },
    {
      id: 3,
      pageNumber: 3,
      bookId: typedArgs?.bookId ?? 0,
      data: 'Neural networks give rise to consciousness.',
      snippet: 'Neural networks give rise to <mark>consciousness</mark>.',
    },
  ];
});

const ftsResults = await invoke('search_book_text', {
  query: 'consciousness',
  bookId: 1,
});
assert(Array.isArray(ftsResults), 'search_book_text should return an array');
assert(
  (ftsResults).length === 2,
  'FTS should return 2 results'
);
const ftsFirst = (ftsResults)[0];
assert(
  ftsFirst.snippet.includes('<mark>'),
  'FTS snippet should contain <mark> highlight tags'
);

snapshot.take('after-full-search-flow');

// ============================
// Test 5: Verify IPC log captures the full command chain
// ============================
const allLog = ipc.log;

const searchLog = allLog.filter((e) => e.command === 'search_vectors');
assert(
  searchLog.length === 2,
  'search_vectors should appear twice in IPC log (1 success + 1 error), got ' +
    searchLog.length
);

const embedLog = allLog.filter((e) => e.command === 'embed');
assert(embedLog.length === 1, 'embed should appear once in IPC log');

const contextLog = allLog.filter(
  (e) => e.command === 'get_context_for_query'
);
assert(contextLog.length === 1, 'get_context_for_query should appear once in IPC log');

const ftsLog = allLog.filter(
  (e) => e.command === 'search_book_text'
);
assert(ftsLog.length === 1, 'search_book_text should appear once in IPC log');

// All intercepted commands should be marked as mocked
const mockedCommands = allLog.filter((e) => e.mocked === true);
assert(
  mockedCommands.length >= 5,
  'At least 5 commands should be marked as mocked, got ' + mockedCommands.length
);

snapshot.take('search-tests-complete');
