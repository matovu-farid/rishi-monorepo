// @ts-nocheck
// DjVu reader E2E test
// Tests the DjVu reading flow: loading metadata, page-by-page navigation,
// page rendering (PNG bytes), text extraction, and verifying the page
// loading sequence in the IPC log.
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
// Setup: realistic DjVu data
// ============================
const djvuFilePath = '/Users/testuser/Books/mathematics-intro.djvu';

const mockDjvuData = {
  id: 'djvu-math-001',
  kind: 'djvu',
  cover: [0x41, 0x54, 0x26, 0x54], // AT&T magic bytes for DjVu
  title: 'Introduction to Mathematics',
  author: 'Alfred North Whitehead',
  publisher: 'Williams and Norgate',
  filepath: djvuFilePath,
  location: '',
  coverKind: 'image/png',
  version: 0,
};

// Fake PNG bytes for rendered pages (realistic header + varying body size)
function makeFakePagePng(pageNum) {
  const header = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  // Add IHDR chunk with page-specific data so pages have different sizes
  const ihdr = [0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52];
  const pageData = Array(20 + pageNum * 5).fill(pageNum & 0xff);
  return [...header, ...ihdr, ...pageData];
}

const mockPageText = {
  1: [
    'The study of mathematics is apt to commence in disappointment.',
    'The important applications of ideas, of which the first vague beginnings are so simple.',
  ],
  2: [
    'The nature of the original elements which mathematics investigates.',
    'Algebra and Geometry are two great branches of abstract mathematics.',
  ],
  3: [
    'The notion of variable is a fundamental idea in all higher mathematics.',
    'Functions express the idea of one quantity depending on another.',
  ],
  4: [
    'The idea of number is evidently so extremely simple.',
    'We can easily distinguish the difference between 1, 2, 3, and 4.',
  ],
  5: [
    'Geometry deals with the properties of space.',
    'The fundamental notions are those of points, lines, and planes.',
  ],
};

// ============================
// Test 1: Load DjVu metadata
// ============================
bridge.mockCommand('get_djvu_data', mockDjvuData);

const djvuData = await invoke('get_djvu_data', { path: djvuFilePath });
assert(djvuData !== null, 'get_djvu_data should return book data');
const typedDjvuData = djvuData;
assert(
  typedDjvuData.title === 'Introduction to Mathematics',
  'Title should be "Introduction to Mathematics", got "' + typedDjvuData.title + '"'
);
assert(typedDjvuData.kind === 'djvu', 'Kind should be "djvu"');
assert(typedDjvuData.author === 'Alfred North Whitehead', 'Author should match');
assert(
  typedDjvuData.filepath === djvuFilePath,
  'Filepath should match'
);

snapshot.take('after-get-djvu-data');

// ============================
// Test 2: Get page count
// ============================
const totalPages = 5;
bridge.mockCommand('get_djvu_page_count', totalPages);

const pageCount = await invoke('get_djvu_page_count', { path: djvuFilePath });
assert(pageCount === totalPages, 'Page count should be 5, got ' + pageCount);

snapshot.take('after-get-page-count');

// ============================
// Test 3: Render pages as PNG (simulate page-by-page navigation)
// ============================
let pageRenderLog = [];

bridge.interceptCommand('get_djvu_page', (args) => {
  const typedArgs = args;
  const pageNum = typedArgs?.pageNumber ?? 1;
  const dpi = typedArgs?.dpi ?? 300;
  pageRenderLog.push({ page: pageNum, dpi });

  assert(
    typedArgs?.path === djvuFilePath,
    'Page render should use correct file path'
  );
  assert(
    pageNum >= 1 && pageNum <= totalPages,
    'Page number should be between 1 and ' + totalPages + ', got ' + pageNum
  );
  assert(
    dpi > 0 && dpi <= 600,
    'DPI should be between 1 and 600, got ' + dpi
  );

  return makeFakePagePng(pageNum);
});

// Navigate through first 3 pages at 300 DPI
for (let page = 1; page <= 3; page++) {
  const pngBytes = await invoke('get_djvu_page', {
    path: djvuFilePath,
    pageNumber: page,
    dpi: 300,
  });

  assert(Array.isArray(pngBytes), 'Page ' + page + ' should return byte array');
  const bytes = pngBytes;
  assert(bytes.length > 0, 'Page ' + page + ' PNG should not be empty');
  // Verify PNG magic bytes
  assert(
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47,
    'Page ' + page + ' data should start with PNG magic bytes'
  );
}

assert(
  pageRenderLog.length === 3,
  'Should have rendered 3 pages, got ' + pageRenderLog.length
);
assert(pageRenderLog[0].page === 1, 'First rendered page should be 1');
assert(pageRenderLog[1].page === 2, 'Second rendered page should be 2');
assert(pageRenderLog[2].page === 3, 'Third rendered page should be 3');
assert(pageRenderLog[0].dpi === 300, 'All renders should use 300 DPI');

snapshot.take('after-page-rendering');

// ============================
// Test 4: Jump to a specific page
// ============================
const jumpPng = await invoke('get_djvu_page', {
  path: djvuFilePath,
  pageNumber: 5,
  dpi: 300,
});

assert(Array.isArray(jumpPng), 'Jump-to page should return bytes');
assert(
  pageRenderLog[3].page === 5,
  'Fourth render request should be for page 5 (jump)'
);

// Render page 5 at higher DPI (zoom)
const zoomPng = await invoke('get_djvu_page', {
  path: djvuFilePath,
  pageNumber: 5,
  dpi: 600,
});

assert(Array.isArray(zoomPng), 'Zoomed page should return bytes');
assert(
  pageRenderLog[4].dpi === 600,
  'Fifth render should be at 600 DPI (zoom)'
);

snapshot.take('after-page-jump-and-zoom');

// ============================
// Test 5: Extract text from pages
// ============================
let textRequestLog = [];

bridge.interceptCommand('get_djvu_page_text', (args) => {
  const typedArgs = args;
  const pageNum = typedArgs?.pageNumber ?? 1;
  textRequestLog.push(pageNum);

  assert(
    typedArgs?.path === djvuFilePath,
    'Text extraction should use correct file path'
  );

  const text = mockPageText[pageNum];
  if (text === undefined) {
    throw new Error('No text for page ' + pageNum);
  }
  return text;
});

// Extract text from pages 1-3
for (let page = 1; page <= 3; page++) {
  const textSegments = await invoke('get_djvu_page_text', {
    path: djvuFilePath,
    pageNumber: page,
  });

  assert(
    Array.isArray(textSegments),
    'get_djvu_page_text should return string array for page ' + page
  );
  const segments = textSegments;
  assert(segments.length === 2, 'Page ' + page + ' should have 2 text segments');
}

// Verify text extraction log
assert(
  textRequestLog.length === 3,
  'Should have extracted text from 3 pages'
);
assert(textRequestLog[0] === 1, 'First text extraction should be page 1');
assert(textRequestLog[1] === 2, 'Second text extraction should be page 2');
assert(textRequestLog[2] === 3, 'Third text extraction should be page 3');

// Verify specific content
const page1Text = await invoke('get_djvu_page_text', {
  path: djvuFilePath,
  pageNumber: 1,
});
const p1Segments = page1Text;
assert(
  p1Segments[0].includes('mathematics'),
  'Page 1 first segment should mention mathematics'
);

snapshot.take('after-text-extraction');

// ============================
// Test 6: Save reading progress
// ============================
let progressUpdates = [];

bridge.interceptCommand('update_book_location', (args) => {
  const typedArgs = args;
  progressUpdates.push({
    bookId: typedArgs?.bookId ?? 0,
    location: typedArgs?.newLocation ?? '',
  });
  return null;
});

// Save progress at pages 1, 3, and 5
for (const page of [1, 3, 5]) {
  await invoke('update_book_location', {
    bookId: 1,
    newLocation: 'djvu:page:' + page,
  });
}

assert(progressUpdates.length === 3, 'Should have 3 progress updates');
assert(progressUpdates[0].location === 'djvu:page:1', 'First progress should be page 1');
assert(progressUpdates[1].location === 'djvu:page:3', 'Second progress should be page 3');
assert(progressUpdates[2].location === 'djvu:page:5', 'Third progress should be page 5');

snapshot.take('after-progress-saves');

// ============================
// Test 7: Verify complete IPC log and page loading sequence
// ============================
const allLog = ipc.log;

// Verify get_djvu_data
const getDjvuDataLog = allLog.filter((e) => e.command === 'get_djvu_data');
assert(getDjvuDataLog.length === 1, 'get_djvu_data should appear once');

// Verify get_djvu_page_count
const pageCountLog = allLog.filter(
  (e) => e.command === 'get_djvu_page_count'
);
assert(pageCountLog.length === 1, 'get_djvu_page_count should appear once');

// Verify get_djvu_page calls (3 sequential + 1 jump + 1 zoom = 5)
const pageLog = allLog.filter((e) => e.command === 'get_djvu_page');
assert(
  pageLog.length === 5,
  'get_djvu_page should appear 5 times, got ' + pageLog.length
);

// Verify get_djvu_page_text calls (3 in loop + 1 extra = 4)
const textLog = allLog.filter((e) => e.command === 'get_djvu_page_text');
assert(
  textLog.length === 4,
  'get_djvu_page_text should appear 4 times, got ' + textLog.length
);

// Verify update_book_location calls
const locationLog = allLog.filter(
  (e) => e.command === 'update_book_location'
);
assert(
  locationLog.length === 3,
  'update_book_location should appear 3 times, got ' + locationLog.length
);

// Verify all entries are mocked
const allMocked = allLog.every((e) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

// Verify ordering: metadata -> page count -> page renders -> text -> progress
const commandSequence = allLog.map((e) => e.command);
const dataIdx = commandSequence.indexOf('get_djvu_data');
const countIdx = commandSequence.indexOf('get_djvu_page_count');
const firstPageIdx = commandSequence.indexOf('get_djvu_page');
const firstTextIdx = commandSequence.indexOf('get_djvu_page_text');
assert(dataIdx < countIdx, 'get_djvu_data should come before get_djvu_page_count');
assert(countIdx < firstPageIdx, 'get_djvu_page_count should come before first page render');
assert(firstPageIdx < firstTextIdx, 'Page rendering should come before text extraction');

snapshot.take('djvu-reader-tests-complete');
