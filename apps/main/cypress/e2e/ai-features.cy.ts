// @ts-nocheck
// AI features E2E test
// Tests the full AI/embedding pipeline: embedding text, saving vectors,
// searching vectors, retrieving context, and processing jobs.
// Verifies the complete embed -> save -> search -> context chain via IPC log.
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
// Setup: shared constants and helpers
// ============================
const EMBED_DIM = 384; // all-MiniLM-L6-v2 output dimension
const BOOK_ID = 1;
const VECTOR_DB_NAME = BOOK_ID + '-vectordb';

// Generate a deterministic fake embedding from a seed
function fakeEmbedding(seed) {
  const vec = [];
  for (let i = 0; i < EMBED_DIM; i++) {
    vec.push(Math.sin(seed * 1000 + i) * 0.1);
  }
  return vec;
}

// Test data: page chunks with realistic text
const testChunks = [
  {
    id: 1001,
    pageNumber: 1,
    bookId: BOOK_ID,
    text: 'The philosophy of consciousness has been debated for centuries across many cultures and traditions.',
  },
  {
    id: 1002,
    pageNumber: 2,
    bookId: BOOK_ID,
    text: 'Quantum mechanics describes the behavior of particles at atomic and subatomic scales.',
  },
  {
    id: 1003,
    pageNumber: 3,
    bookId: BOOK_ID,
    text: 'Neural networks in the brain give rise to consciousness and self-awareness.',
  },
  {
    id: 1004,
    pageNumber: 4,
    bookId: BOOK_ID,
    text: 'Machine learning algorithms can approximate complex mathematical functions through optimization.',
  },
  {
    id: 1005,
    pageNumber: 5,
    bookId: BOOK_ID,
    text: 'The double slit experiment demonstrates the wave-particle duality of quantum objects.',
  },
];

// ============================
// Test 1: Embed text into vectors
// ============================
let embedCallCount = 0;
let _lastEmbedArgs = null;

bridge.interceptCommand('embed', (args) => {
  embedCallCount++;
  _lastEmbedArgs = args;

  const typedArgs = args;

  assert(
    typedArgs?.embedparams !== undefined && typedArgs.embedparams.length > 0,
    'embed requires non-empty embedparams'
  );

  // Generate mock embeddings for each input
  return (typedArgs.embedparams ?? []).map((param, idx) => ({
    dim: EMBED_DIM,
    embedding: fakeEmbedding(param.metadata.id + idx),
    text: param.text,
    metadata: param.metadata,
  }));
});

const embedParams = testChunks.map(chunk => ({
  text: chunk.text,
  metadata: { id: chunk.id, pageNumber: chunk.pageNumber, bookId: chunk.bookId },
}));

const embedResults = await invoke('embed', { embedparams: embedParams });
assert(embedCallCount === 1, 'embed should be called once');
assert(Array.isArray(embedResults), 'embed should return an array');

const typedEmbedResults = embedResults;

assert(
  typedEmbedResults.length === 5,
  'Should return 5 embeddings, got ' + typedEmbedResults.length
);
assert(
  typedEmbedResults[0].dim === EMBED_DIM,
  'Embedding dimension should be ' + EMBED_DIM + ', got ' + typedEmbedResults[0].dim
);
assert(
  typedEmbedResults[0].embedding.length === EMBED_DIM,
  'Embedding vector should have ' + EMBED_DIM + ' elements'
);
assert(
  typedEmbedResults[0].metadata.id === 1001,
  'First embedding metadata id should be 1001'
);
assert(
  typedEmbedResults[0].metadata.bookId === BOOK_ID,
  'Embedding metadata bookId should match'
);

snapshot.take('after-embed');

// ============================
// Test 2: Save vectors to vector database
// ============================
let saveVectorsCallCount = 0;
let saveVectorsArgs = null;

bridge.interceptCommand('save_vectors', (args) => {
  saveVectorsCallCount++;
  saveVectorsArgs = args;

  const typedArgs = args;

  assert(
    typedArgs?.name === VECTOR_DB_NAME,
    'save_vectors name should be "' + VECTOR_DB_NAME + '", got "' + typedArgs?.name + '"'
  );
  assert(
    typedArgs?.dim === EMBED_DIM,
    'save_vectors dim should be ' + EMBED_DIM
  );
  assert(
    Array.isArray(typedArgs?.vectors) && typedArgs.vectors.length > 0,
    'save_vectors requires non-empty vectors array'
  );

  // Verify each vector has correct dimension
  for (const vec of (typedArgs.vectors ?? [])) {
    assert(
      vec.vector.length === EMBED_DIM,
      'Vector ' + vec.id + ' should have ' + EMBED_DIM + ' dimensions, got ' + vec.vector.length
    );
  }

  return null; // returns void
});

// Build vectors from embed results
const vectors = typedEmbedResults.map(result => ({
  id: result.metadata.id,
  vector: result.embedding,
}));

await invoke('save_vectors', {
  name: VECTOR_DB_NAME,
  dim: EMBED_DIM,
  vectors: vectors,
});

assert(saveVectorsCallCount === 1, 'save_vectors should be called once');

const savedVecArgs = saveVectorsArgs;
assert(
  savedVecArgs.vectors?.length === 5,
  'Should have saved 5 vectors'
);

snapshot.take('after-save-vectors');

// ============================
// Test 3: Search vectors
// ============================
let searchVectorsCallCount = 0;

bridge.interceptCommand('search_vectors', (args) => {
  searchVectorsCallCount++;
  const typedArgs = args;

  assert(
    typedArgs?.name === VECTOR_DB_NAME,
    'search_vectors name should match vector db name'
  );
  assert(
    typedArgs?.dim === EMBED_DIM,
    'search_vectors dim should match embedding dimension'
  );
  assert(
    Array.isArray(typedArgs?.query) && typedArgs.query.length === EMBED_DIM,
    'search_vectors query should be a vector of dimension ' + EMBED_DIM
  );
  assert(
    typeof typedArgs?.k === 'number' && typedArgs.k > 0,
    'search_vectors k should be a positive number'
  );

  // Return mock results: closest to "consciousness" query
  return [
    { id: 1001, distance: 0.12 },  // consciousness text
    { id: 1003, distance: 0.18 },  // neural networks / consciousness text
    { id: 1002, distance: 0.65 },  // quantum mechanics (less relevant)
  ];
});

const queryVector = fakeEmbedding(9999); // fake query embedding
const searchResults = await invoke('search_vectors', {
  name: VECTOR_DB_NAME,
  query: queryVector,
  dim: EMBED_DIM,
  k: 3,
});

assert(searchVectorsCallCount === 1, 'search_vectors should be called once');
assert(Array.isArray(searchResults), 'search_vectors should return an array');

const typedSearchResults = searchResults;
assert(typedSearchResults.length === 3, 'Should return 3 search results');
assert(typedSearchResults[0].id === 1001, 'Closest result should be id 1001');
assert(typedSearchResults[0].distance === 0.12, 'Closest distance should be 0.12');
assert(
  typedSearchResults[0].distance <= typedSearchResults[1].distance,
  'Results should be sorted by distance (ascending)'
);
assert(
  typedSearchResults[1].distance <= typedSearchResults[2].distance,
  'Results should be sorted by distance (ascending)'
);

snapshot.take('after-search-vectors');

// ============================
// Test 4: Get context for query (full pipeline)
// ============================
let contextCallCount = 0;

bridge.interceptCommand('get_context_for_query', (args) => {
  contextCallCount++;
  const typedArgs = args;

  assert(
    typeof typedArgs?.queryText === 'string' && typedArgs.queryText.length > 0,
    'get_context_for_query requires non-empty queryText'
  );
  assert(
    typeof typedArgs?.bookId === 'number',
    'get_context_for_query requires bookId'
  );
  assert(
    typeof typedArgs?.k === 'number' && typedArgs.k > 0,
    'get_context_for_query requires positive k'
  );

  // Return matching text passages
  return [
    'The philosophy of consciousness has been debated for centuries across many cultures and traditions.',
    'Neural networks in the brain give rise to consciousness and self-awareness.',
  ];
});

const contextResults = await invoke('get_context_for_query', {
  queryText: 'What is consciousness?',
  bookId: BOOK_ID,
  k: 3,
});

assert(contextCallCount === 1, 'get_context_for_query should be called once');
assert(Array.isArray(contextResults), 'get_context_for_query should return an array');

const typedContext = contextResults;
assert(typedContext.length === 2, 'Should return 2 context passages');
assert(
  typedContext[0].includes('consciousness'),
  'First passage should mention consciousness'
);
assert(
  typedContext[1].includes('Neural networks'),
  'Second passage should mention neural networks'
);

snapshot.take('after-get-context');

// ============================
// Test 5: Process job (embed + save combined workflow)
// ============================
let processJobCallCount = 0;
let processJobArgs = null;

bridge.interceptCommand('process_job', (args) => {
  processJobCallCount++;
  processJobArgs = args;

  const typedArgs = args;

  assert(
    typeof typedArgs?.pageNumber === 'number',
    'process_job requires pageNumber'
  );
  assert(
    typeof typedArgs?.bookId === 'number',
    'process_job requires bookId'
  );
  assert(
    Array.isArray(typedArgs?.pageData) && typedArgs.pageData.length > 0,
    'process_job requires non-empty pageData'
  );

  return null; // returns void
});

const jobPageData = [
  { id: 2001, pageNumber: 10, bookId: BOOK_ID, data: 'New content for page 10 about advanced topics in consciousness studies.' },
  { id: 2002, pageNumber: 10, bookId: BOOK_ID, data: 'Additional paragraph about the hard problem of consciousness.' },
];

await invoke('process_job', {
  pageNumber: 10,
  bookId: BOOK_ID,
  pageData: jobPageData,
});

assert(processJobCallCount === 1, 'process_job should be called once');

const jobArgs = processJobArgs;
assert(jobArgs.pageNumber === 10, 'Job page number should be 10');
assert(jobArgs.bookId === BOOK_ID, 'Job book ID should match');
assert(jobArgs.pageData?.length === 2, 'Job should have 2 page data entries');

snapshot.take('after-process-job');

// ============================
// Test 6: Chain multiple operations to simulate full AI pipeline
// ============================

// Step 1: Embed new text
const newEmbedResults = await invoke('embed', {
  embedparams: [
    { text: 'What is the nature of consciousness?', metadata: { id: 0, pageNumber: 0, bookId: BOOK_ID } },
  ],
});

assert(embedCallCount === 2, 'embed should now be called twice');
const newEmbed = (newEmbedResults)[0];
assert(newEmbed.embedding.length === EMBED_DIM, 'New embedding should have correct dimension');

// Step 2: Search using the new embedding
const pipelineSearch = await invoke('search_vectors', {
  name: VECTOR_DB_NAME,
  query: newEmbed.embedding,
  dim: EMBED_DIM,
  k: 2,
});

assert(searchVectorsCallCount === 2, 'search_vectors should now be called twice');
assert(
  (pipelineSearch).length === 3,
  'Pipeline search should return results'
);

// Step 3: Get text for the vector IDs
bridge.interceptCommand('get_text_from_vector_id', (args) => {
  const typedArgs = args;
  const textMap = {
    1001: testChunks[0].text,
    1002: testChunks[1].text,
    1003: testChunks[2].text,
    1004: testChunks[3].text,
    1005: testChunks[4].text,
  };
  return textMap[typedArgs?.vectorId ?? 0] || '';
});

const topResultIds = (pipelineSearch).slice(0, 2);
for (const result of topResultIds) {
  const text = await invoke('get_text_from_vector_id', { vectorId: result.id });
  assert(typeof text === 'string', 'get_text_from_vector_id should return a string');
  assert((text).length > 0, 'Retrieved text should not be empty');
}

snapshot.take('after-full-ai-pipeline');

// ============================
// Test 7: Verify complete IPC log
// ============================
const allLog = ipc.log;

// Verify embed calls (initial batch + pipeline query = 2)
const embedLog = allLog.filter((e) => e.command === 'embed');
assert(
  embedLog.length === 2,
  'embed should appear twice in IPC log, got ' + embedLog.length
);
assert(embedLog[0].mocked === true, 'embed calls should be mocked');

// Verify save_vectors
const saveVecLog = allLog.filter((e) => e.command === 'save_vectors');
assert(saveVecLog.length === 1, 'save_vectors should appear once');

// Verify search_vectors (initial + pipeline = 2)
const searchLog = allLog.filter((e) => e.command === 'search_vectors');
assert(
  searchLog.length === 2,
  'search_vectors should appear twice, got ' + searchLog.length
);

// Verify get_context_for_query
const contextLog = allLog.filter(
  (e) => e.command === 'get_context_for_query'
);
assert(contextLog.length === 1, 'get_context_for_query should appear once');

// Verify process_job
const jobLog = allLog.filter((e) => e.command === 'process_job');
assert(jobLog.length === 1, 'process_job should appear once');

// Verify get_text_from_vector_id (2 calls for top 2 results)
const textLog = allLog.filter(
  (e) => e.command === 'get_text_from_vector_id'
);
assert(
  textLog.length === 2,
  'get_text_from_vector_id should appear twice, got ' + textLog.length
);

// Verify all entries are mocked
const allMocked = allLog.every((e) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

// Verify the pipeline ordering: embed -> save -> search -> context -> job
const commandOrder = allLog.map((e) => e.command);
const firstEmbedIdx = commandOrder.indexOf('embed');
const saveVecIdx = commandOrder.indexOf('save_vectors');
const firstSearchIdx = commandOrder.indexOf('search_vectors');
const contextIdx = commandOrder.indexOf('get_context_for_query');
const jobIdx = commandOrder.indexOf('process_job');

assert(firstEmbedIdx < saveVecIdx, 'embed should come before save_vectors');
assert(saveVecIdx < firstSearchIdx, 'save_vectors should come before search_vectors');
assert(firstSearchIdx < contextIdx, 'search_vectors should come before get_context_for_query');
assert(contextIdx < jobIdx, 'get_context_for_query should come before process_job');

snapshot.take('ai-features-tests-complete');
