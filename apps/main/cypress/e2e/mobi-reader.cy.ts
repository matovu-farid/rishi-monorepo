// @ts-nocheck
// MOBI reader E2E test
// Tests the MOBI reading flow: loading book metadata, chapter-by-chapter
// navigation, text extraction, and verifying the chapter loading sequence
// in the IPC log.
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
// Setup: realistic MOBI data
// ============================
const mobiFilePath = '/Users/testuser/Books/moby-dick.mobi';

const mockMobiData = {
  id: 'mobi-moby-dick-001',
  kind: 'mobi',
  cover: [0x00, 0x00, 0x00, 0x00, 0x42, 0x4f, 0x4f, 0x4b], // MOBI header bytes
  title: 'Moby Dick',
  author: 'Herman Melville',
  publisher: 'Harper & Brothers',
  filepath: mobiFilePath,
  location: '',
  coverKind: 'image/jpeg',
  version: 0,
};

const mockChapters = {
  0: '<h1>Loomings</h1><p>Call me Ishmael. Some years ago - never mind how long precisely - having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.</p>',
  1: '<h1>The Carpet-Bag</h1><p>I stuffed a shirt or two into my old carpet-bag, tucked it under my arm, and started for Cape Horn and the Pacific.</p>',
  2: '<h1>The Spouter-Inn</h1><p>Entering that gable-ended Spouter-Inn, you found yourself in a wide, low, straggling entry with old-fashioned wainscots.</p>',
  3: '<h1>The Counterpane</h1><p>Upon waking next morning about daylight, I found Queequeg\'s arm thrown over me in the most loving and affectionate manner.</p>',
  4: '<h1>Breakfast</h1><p>I quickly followed suit, and descending into the bar-room accosted the grinning landlord very pleasantly.</p>',
};

const mockChapterText = {
  0: [
    'Call me Ishmael.',
    'Some years ago - never mind how long precisely - having little or no money in my purse.',
    'Nothing particular to interest me on shore, I thought I would sail about a little.',
  ],
  1: [
    'I stuffed a shirt or two into my old carpet-bag.',
    'Tucked it under my arm, and started for Cape Horn and the Pacific.',
  ],
  2: [
    'Entering that gable-ended Spouter-Inn.',
    'You found yourself in a wide, low, straggling entry with old-fashioned wainscots.',
  ],
  3: [
    'Upon waking next morning about daylight.',
    'I found Queequeg\'s arm thrown over me in the most loving and affectionate manner.',
  ],
  4: [
    'I quickly followed suit.',
    'Descending into the bar-room accosted the grinning landlord very pleasantly.',
  ],
};

// ============================
// Test 1: Load MOBI metadata
// ============================
bridge.mockCommand('get_mobi_data', mockMobiData);

const mobiData = await invoke('get_mobi_data', { path: mobiFilePath });
assert(mobiData !== null, 'get_mobi_data should return book data');
const typedMobiData = mobiData;
assert(typedMobiData.title === 'Moby Dick', 'Title should be "Moby Dick"');
assert(typedMobiData.kind === 'mobi', 'Kind should be "mobi"');
assert(typedMobiData.author === 'Herman Melville', 'Author should be Herman Melville');
assert(typedMobiData.publisher === 'Harper & Brothers', 'Publisher should match');

snapshot.take('after-get-mobi-data');

// ============================
// Test 2: Get chapter count
// ============================
const totalChapters = 5;
bridge.mockCommand('get_mobi_chapter_count', totalChapters);

const chapterCount = await invoke('get_mobi_chapter_count', { path: mobiFilePath });
assert(chapterCount === totalChapters, 'Chapter count should be 5, got ' + chapterCount);

snapshot.take('after-get-chapter-count');

// ============================
// Test 3: Load chapters sequentially (simulate reader navigating)
// ============================
let chapterRequestLog = [];

bridge.interceptCommand('get_mobi_chapter', (args) => {
  const typedArgs = args;
  const idx = typedArgs?.chapterIndex ?? 0;
  chapterRequestLog.push(idx);

  assert(
    typedArgs?.path === mobiFilePath,
    'Chapter request should use correct file path'
  );

  const html = mockChapters[idx];
  if (html === undefined) {
    throw new Error('Chapter index ' + idx + ' out of range');
  }
  return html;
});

// Read first 3 chapters in order
for (let i = 0; i < 3; i++) {
  const chapterHtml = await invoke('get_mobi_chapter', {
    path: mobiFilePath,
    chapterIndex: i,
  });

  assert(typeof chapterHtml === 'string', 'Chapter ' + i + ' should return HTML string');
  const html = chapterHtml;
  assert(html.includes('<h1>'), 'Chapter ' + i + ' HTML should contain an h1 heading');
  assert(html.includes('<p>'), 'Chapter ' + i + ' HTML should contain paragraph content');
}

// Verify chapters were loaded in order
assert(
  chapterRequestLog.length === 3,
  'Should have loaded 3 chapters, got ' + chapterRequestLog.length
);
assert(chapterRequestLog[0] === 0, 'First chapter loaded should be index 0');
assert(chapterRequestLog[1] === 1, 'Second chapter loaded should be index 1');
assert(chapterRequestLog[2] === 2, 'Third chapter loaded should be index 2');

snapshot.take('after-sequential-chapter-load');

// ============================
// Test 4: Jump to a specific chapter (simulate user navigation)
// ============================
const jumpChapterHtml = await invoke('get_mobi_chapter', {
  path: mobiFilePath,
  chapterIndex: 4,
});

assert(typeof jumpChapterHtml === 'string', 'Jump-to chapter should return HTML');
assert(
  (jumpChapterHtml).includes('Breakfast'),
  'Chapter 4 should be the Breakfast chapter'
);
assert(chapterRequestLog[3] === 4, 'Fourth request should be for chapter 4 (jump)');

snapshot.take('after-chapter-jump');

// ============================
// Test 5: Extract text from chapters via get_mobi_text
// ============================
let textRequestLog = [];

bridge.interceptCommand('get_mobi_text', (args) => {
  const typedArgs = args;
  const idx = typedArgs?.chapterIndex ?? 0;
  textRequestLog.push(idx);

  const text = mockChapterText[idx];
  if (text === undefined) {
    throw new Error('No text for chapter index ' + idx);
  }
  return text;
});

// Extract text from chapters 0-2
for (let i = 0; i < 3; i++) {
  const textSegments = await invoke('get_mobi_text', {
    path: mobiFilePath,
    chapterIndex: i,
  });

  assert(Array.isArray(textSegments), 'get_mobi_text should return string array for chapter ' + i);
  const segments = textSegments;
  assert(segments.length > 0, 'Chapter ' + i + ' should have at least one text segment');
}

// Verify text extraction order
assert(
  textRequestLog.length === 3,
  'Should have extracted text from 3 chapters'
);
assert(textRequestLog[0] === 0, 'First text extraction should be chapter 0');
assert(textRequestLog[1] === 1, 'Second text extraction should be chapter 1');
assert(textRequestLog[2] === 2, 'Third text extraction should be chapter 2');

// Verify first chapter text content
const ch0Text = await invoke('get_mobi_text', {
  path: mobiFilePath,
  chapterIndex: 0,
});
const ch0Segments = ch0Text;
assert(
  ch0Segments[0] === 'Call me Ishmael.',
  'First segment of chapter 0 should be the famous opening line'
);

snapshot.take('after-text-extraction');

// ============================
// Test 6: Simulate full read-through and save progress
// ============================
let locationUpdates = [];

bridge.interceptCommand('update_book_location', (args) => {
  const typedArgs = args;
  if (typedArgs?.newLocation) {
    locationUpdates.push(typedArgs.newLocation);
  }
  return null;
});

// Simulate reading through all 5 chapters and saving progress after each
for (let i = 0; i < totalChapters; i++) {
  await invoke('update_book_location', {
    bookId: 1,
    newLocation: 'mobi:chapter:' + i,
  });
}

assert(
  locationUpdates.length === 5,
  'Should have 5 location updates, got ' + locationUpdates.length
);
assert(locationUpdates[0] === 'mobi:chapter:0', 'First update should be chapter 0');
assert(locationUpdates[4] === 'mobi:chapter:4', 'Last update should be chapter 4');

snapshot.take('after-progress-tracking');

// ============================
// Test 7: Verify complete IPC log and chapter loading sequence
// ============================
const allLog = ipc.log;

// Verify get_mobi_data
const getMobiDataLog = allLog.filter((e) => e.command === 'get_mobi_data');
assert(getMobiDataLog.length === 1, 'get_mobi_data should appear once');
assert(getMobiDataLog[0].mocked === true, 'get_mobi_data should be mocked');

// Verify get_mobi_chapter_count
const chapterCountLog = allLog.filter(
  (e) => e.command === 'get_mobi_chapter_count'
);
assert(chapterCountLog.length === 1, 'get_mobi_chapter_count should appear once');

// Verify get_mobi_chapter calls (3 sequential + 1 jump = 4)
const chapterLog = allLog.filter((e) => e.command === 'get_mobi_chapter');
assert(
  chapterLog.length === 4,
  'get_mobi_chapter should appear 4 times, got ' + chapterLog.length
);

// Verify get_mobi_text calls (3 in loop + 1 extra = 4)
const textLog = allLog.filter((e) => e.command === 'get_mobi_text');
assert(
  textLog.length === 4,
  'get_mobi_text should appear 4 times, got ' + textLog.length
);

// Verify update_book_location calls (5 total for full read-through)
const locationLog = allLog.filter(
  (e) => e.command === 'update_book_location'
);
assert(
  locationLog.length === 5,
  'update_book_location should appear 5 times, got ' + locationLog.length
);

// Verify all entries are mocked
const allMocked = allLog.every((e) => e.mocked === true);
assert(allMocked, 'All IPC entries should be marked as mocked');

// Verify the loading sequence: data -> count -> chapters -> text -> progress
const commandSequence = allLog.map((e) => e.command);
const dataIdx = commandSequence.indexOf('get_mobi_data');
const countIdx = commandSequence.indexOf('get_mobi_chapter_count');
const firstChapterIdx = commandSequence.indexOf('get_mobi_chapter');
assert(dataIdx < countIdx, 'get_mobi_data should come before get_mobi_chapter_count');
assert(countIdx < firstChapterIdx, 'get_mobi_chapter_count should come before first get_mobi_chapter');

snapshot.take('mobi-reader-tests-complete');
