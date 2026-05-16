# Read Aloud From Selection — Manual Smoke Test

Pre-conditions: app built from `read-aloud-phase-0-gesture` branch, EPUB fixture loaded.

## Test path 1 — Popover button

1. Open an EPUB.
2. Drag-select a sentence in the middle of a paragraph.
3. Expect: SelectionPopover appears with highlight colors AND a Play icon button (first item, before the color swatches).
4. Click the Play icon button.
5. Expect: TTS playback starts from the SELECTED sentence (not from the top of the paragraph).

## Test path 2 — Native context menu

1. With an EPUB open, select a sentence mid-paragraph.
2. Right-click on the selection.
3. Expect: native OS context menu appears with a single item "Read Aloud From Here".
4. Click it.
5. Expect: TTS playback starts from the selected sentence.

## Test path 3 — Keyboard shortcut with selection

1. With an EPUB open, select a sentence mid-paragraph.
2. Press ⌘⇧L (CmdOrCtrl+Shift+L).
3. Expect: TTS playback starts from the selected sentence.

## Test path 4 — Keyboard shortcut without selection (fallback)

1. With an EPUB open, ensure NO text is selected (click elsewhere to clear).
2. Press ⌘⇧L.
3. Expect: existing Read Aloud command fires (toggles play/pause from the current position).

## Test path 5 — Interrupt + restart

1. Start playback via path 1, 2, or 3.
2. While audio is playing, select a different sentence further down the page.
3. Trigger Read Aloud From Here again.
4. Expect: previous audio stops; new playback starts from the new selection.

## Test path 6 — Page navigation clears override

1. Trigger Read Aloud From Selection on a sentence.
2. Wait until that sentence finishes (auto-advance to next paragraph).
3. Page-curl to the next page.
4. Expect: clean playback from the next page's first paragraph (no stuck partial-text state).

## Known limitations (v1)

- PDF, AZW3, MOBI not yet supported — context menu still shows but the renderer-side adapter only handles EPUB.
- Trackpad swipe gestures from inside the EPUB iframe don't reach the outer hook (Phase 0 known follow-up).
