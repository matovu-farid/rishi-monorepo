---
status: draft
phase: 06
phase_name: On-Device RAG & AI Conversations
design_system: NativeWind (Tailwind CSS for React Native)
created: 2026-04-06
revised: 2026-04-06
---

# UI-SPEC: Phase 06 - On-Device RAG & AI Conversations

## Design System

**Tool:** NativeWind v4 (Tailwind CSS classes in React Native)
**Component library:** Custom components with @gorhom/bottom-sheet, react-native-reanimated (existing)
**Icon library:** @expo/vector-icons via IconSymbol wrapper (SF Symbols on iOS, MaterialIcons on Android)
**Animation:** react-native-reanimated (FadeIn/FadeOut, existing pattern)

---

## Spacing

Scale: 4px base unit (8-point system). Consistent with Phase 05.

| Token | Value | Usage |
|-------|-------|-------|
| `p-1` | 4px | Icon-to-label gap, inline padding between avatar and message |
| `p-2` | 8px | Inner padding of message bubbles, source reference chips |
| `p-3` | 12px | Message bubble horizontal padding |
| `p-4` | 16px | Screen horizontal padding, vertical gap between messages, input bar padding |
| `p-6` | 24px | Section spacing, conversation list item padding |
| `p-8` | 32px | Empty state vertical padding, model download card padding |

Touch targets: 44x44px minimum (existing pattern: `w-11 h-11`).

Exceptions: none.

---

## Typography

Font family: System fonts via `Fonts` constant (system-ui on iOS, normal on Android). Consistent with Phase 05.

| Role | Size | Weight | Line Height | Tailwind Class |
|------|------|--------|-------------|----------------|
| Sheet/Screen title | 18px | 600 (semibold) | 1.3 | `text-lg font-semibold` |
| Body / message text | 16px | 400 (regular) | 1.5 | `text-base` |
| Secondary / metadata | 14px | 400 (regular) | 1.4 | `text-sm` |
| Source reference text | 13px | 400 (regular) | 1.4 | `text-[13px]` |

Only 2 weights used: regular (400) and semibold (600). Matches existing pattern from Phase 05.

---

## Color

### App Chrome (follows existing Colors constant)

| Role | Light | Dark | Split |
|------|-------|------|-------|
| Dominant surface | `#FFFFFF` | `#151718` | 60% |
| Secondary surface (message bubbles, cards) | `#F3F4F6` (gray-100) | `#1E2022` | 30% |
| Accent (tint) | `#0a7ea4` | `#FFFFFF` | 10% |
| Destructive | `#DC2626` (red-600) | `#DC2626` | -- |
| Icon default | `#687076` | `#9BA1A6` | -- |
| Text primary | `#11181C` | `#ECEDEE` | -- |
| Text secondary | `#687076` (gray-500) | `#9BA1A6` (gray-400) | -- |

### Chat-Specific Colors

| Element | Light | Dark | Notes |
|---------|-------|------|-------|
| User message bubble bg | `#0a7ea4` | `#0a7ea4` | Accent color, white text |
| User message text | `#FFFFFF` | `#FFFFFF` | Always white on accent bg |
| Assistant message bubble bg | `#F3F4F6` (gray-100) | `#2A2D2F` | Secondary surface |
| Assistant message text | `#11181C` | `#ECEDEE` | Primary text color |
| Source reference chip bg | `#E5E7EB` (gray-200) | `#374151` (gray-700) | Subtle, tappable |
| Source reference chip text | `#374151` (gray-700) | `#D1D5DB` (gray-300) | Secondary text |
| Input bar bg | `#FFFFFF` | `#1E2022` | Matches dominant surface |
| Input bar border | `#E5E7EB` (gray-200) | `#374151` (gray-700) | Subtle border-top |
| Progress bar fill | `#0a7ea4` | `#0a7ea4` | Accent for download/embed progress |
| Progress bar track | `#E5E7EB` (gray-200) | `#374151` (gray-700) | Muted track |

### Accent Reserved For

- User message bubble background
- Send button (active state, when input has text)
- Model download progress bar fill
- Embedding progress bar fill
- "Ask about this book" CTA button
- Conversation list new-conversation button

---

## Component Inventory

### New Components

| Component | Type | Purpose | Focal Point |
|-----------|------|---------|-------------|
| `ChatMessage` | View (message bubble) | Renders a single user or assistant message with role-appropriate styling | The message text content -- the reason the user is reading |
| `SourceReference` | Pressable chip | Tappable reference to a book passage within an assistant message | The chapter/page label -- user's eye finds the location reference first |
| `EmbeddingProgress` | View (card with progress bar) | Shows model download and book embedding progress | The progress bar -- user needs to know how far along the process is |
| `ChatInput` | View with TextInput + send button | Fixed bottom input bar for typing questions | The TextInput field -- it is the primary interactive element on the chat screen |
| `ConversationRow` | Pressable list item | Single conversation in the conversations list | The conversation title/first message preview |
| `ModelDownloadCard` | View (full-width card) | Shown on first use when embedding model needs downloading | The download button -- user must act to begin model download |

### New Screens

| Screen | Route | Purpose |
|--------|-------|---------|
| Conversations list | `app/(tabs)/chat.tsx` | New tab showing per-book conversation list |
| Chat screen | `app/chat/[bookId].tsx` | Conversation view for a specific book |

### Modified Components

| Component | Change |
|-----------|--------|
| `app/(tabs)/_layout.tsx` | Add "Chat" tab with `message.fill` icon between Library and Explore |
| `app/reader/[id].tsx` | Add "Ask AI" button to ReaderToolbar that navigates to chat screen for the current book |
| `ReaderToolbar` | Add chat/AI icon button (speech bubble icon) |

### Existing Components (No Changes)

- `TocSheet` -- no changes
- `AppearanceSheet` -- no changes
- `HighlightsSheet` -- no changes
- `BookRow` -- no changes
- `LibraryEmptyState` -- no changes

---

## Layout

### Conversations List Screen (`chat.tsx` tab)

**Focal point:** The first conversation row -- the user opens this tab to resume or start a conversation.

```
+-------------------------------------------+
|  Conversations                      [+]   |
|  ---------------------------------------- |
|  [book cover] Book Title                   |
|  "Last message preview text..."            |
|  2 hours ago                               |
|  ---------------------------------------- |
|  [book cover] Another Book Title           |
|  "What does the author mean by..."         |
|  Yesterday                                 |
|  ---------------------------------------- |
|  ... (scrollable FlatList)                 |
+-------------------------------------------+
|  [Library]  [Chat]  [Explore]              |
+-------------------------------------------+
```

- FlatList sorted by most recent conversation (updatedAt descending)
- Each row: 32x48px book cover thumbnail (left), book title (semibold), last message preview (1 line, secondary text), relative time (text-xs, secondary)
- Row height: auto, with `p-4` vertical padding
- Tapping a row navigates to `chat/[bookId]`
- [+] button: Opens a bottom sheet or modal listing books that have been embedded, allowing the user to start a new conversation
- If no conversations exist, show empty state

### Chat Screen (`chat/[bookId].tsx`)

**Focal point:** The most recent message -- the user's eye starts at the bottom of the message list (inverted FlatList).

```
+-------------------------------------------+
|  < Back    Book Title              [...]   |
|  ---------------------------------------- |
|                                            |
|        [Assistant message bubble]          |
|        Based on chapter 3, the author      |
|        argues that...                      |
|        [Ch. 3, p. 42]  [Ch. 3, p. 45]     |
|                                            |
|                [User message bubble]       |
|                What does the author         |
|                think about X?              |
|                                            |
|        [Assistant message bubble]          |
|        The author discusses X in...        |
|        [Ch. 7, p. 112]                     |
|                                            |
|  ---------------------------------------- |
|  [TextInput: Ask about this book...]  [>]  |
+-------------------------------------------+
```

- Inverted FlatList (newest messages at bottom, matches standard chat pattern)
- Header: back button (left), book title (center, truncated), overflow menu [...] (right)
- User messages: right-aligned, accent background, white text, rounded-2xl with `rounded-br-sm`
- Assistant messages: left-aligned, gray background, primary text, rounded-2xl with `rounded-bl-sm`
- Max bubble width: 80% of screen width
- Source references: row of chips below assistant message text, `gap-2`, horizontally scrollable if more than 3
- Input bar: fixed bottom, border-top, horizontal layout: TextInput (flex-1) + send button (44x44px circle, accent bg when text present, gray when empty)
- Send button icon: `arrow.up` (SF Symbol) / `send` (MaterialIcons), white, 20px
- Keyboard avoiding: `KeyboardAvoidingView` wrapping the entire screen (behavior="padding" on iOS)

### ChatMessage (Message Bubble)

**Focal point:** The message text content.

- User bubble: `bg-[#0a7ea4]` (accent), `text-white`, `rounded-2xl rounded-br-sm`, `px-3 py-2`, max-width 80%
- Assistant bubble: `bg-gray-100 dark:bg-[#2A2D2F]`, primary text, `rounded-2xl rounded-bl-sm`, `px-3 py-2`, max-width 80%
- Timestamps: not shown per-message (conversation context provides temporal flow)
- Loading state (assistant typing): three animated dots in an assistant-colored bubble, FadeIn

### SourceReference (Tappable Chip)

**Focal point:** The chapter/location label.

```
+---------------------------+
|  [book icon] Ch. 3, p. 42 |
+---------------------------+
```

- Pressable, `bg-gray-200 dark:bg-gray-700`, `rounded-full`, `px-3 py-1`
- Text: `text-[13px]`, secondary color
- Book icon: 12px, secondary color, left of text
- Tap action: navigates to the reader at the referenced passage location (using CFI for EPUB, page for PDF)
- Active state: opacity 0.7 on press

### EmbeddingProgress (Progress Card)

**Focal point:** The progress bar -- user needs to see completion status.

```
+-------------------------------------------+
|  [brain icon]                              |
|  Preparing "Book Title" for AI...          |
|  [============================----] 75%    |
|  Embedding 150 of 200 passages             |
+-------------------------------------------+
```

- Full-width card, `bg-gray-50 dark:bg-[#1E2022]`, `rounded-xl`, `p-4`, `mx-4`
- Shown inline at top of chat screen when book is being embedded
- Progress bar: 8px height, `rounded-full`, accent fill, gray-200 track
- Title: `text-base font-semibold`
- Subtitle: `text-sm`, secondary text, shows "Embedding X of Y passages"
- Cancel: not available -- embedding runs to completion once started

### ModelDownloadCard (First-Use Model Download)

**Focal point:** The download button.

```
+-------------------------------------------+
|  [download icon]                           |
|  AI Model Required                         |
|  Download the AI model (80 MB) to ask      |
|  questions about your books.               |
|  [=================-------] 60%            |
|                                            |
|           [Download Model]                 |
+-------------------------------------------+
```

- Full-width card, `bg-gray-50 dark:bg-[#1E2022]`, `rounded-xl`, `p-8`, centered content
- Shown instead of chat UI when model is not downloaded (isReady === false and downloadProgress === 0)
- During download: progress bar replaces button, shows percentage
- Title: `text-lg font-semibold`, centered
- Body: `text-base`, secondary text, centered
- Button: accent bg, white text, semibold, `rounded-lg`, 44px height, full width with `mx-8`
- After download completes: card dismissed, chat UI appears

### ChatInput (Fixed Bottom Input Bar)

**Focal point:** The TextInput field.

```
+-------------------------------------------+
|  [TextInput: Ask about this book...]  [>]  |
+-------------------------------------------+
```

- Fixed at bottom of screen, above keyboard when open
- `border-t border-gray-200 dark:border-gray-700`
- Inner padding: `p-2` around the row, `px-4 py-2` on the TextInput
- TextInput: `bg-gray-100 dark:bg-[#2A2D2F]`, `rounded-full`, `text-base`, flex-1, max 4 lines, multiline
- Placeholder: "Ask about this book...", secondary text color
- Send button: 40x40px circle, right of TextInput, `ml-2`
  - Active (has text): accent bg, white arrow icon
  - Inactive (empty): `bg-gray-200 dark:bg-gray-700`, gray arrow icon, disabled
- While assistant is responding: send button replaced with stop button (square icon, same sizing)

---

## Interaction Contracts

### First-Time Model Download Flow

1. User opens Chat tab or navigates to a book's chat screen for the first time
2. `useTextEmbeddings` reports `isReady === false` and `downloadProgress === 0`
3. ModelDownloadCard displayed with "Download Model" button
4. User taps "Download Model"
5. Progress bar appears, `downloadProgress` updates from 0 to 1
6. On completion (`isReady === true`): card dismissed, normal UI appears
7. Model is cached -- subsequent visits skip download entirely

### Book Embedding Flow

1. User opens chat screen for a book that has not been embedded
2. EmbeddingProgress card appears at top of chat screen
3. Pipeline runs: extract text, chunk (~500 chars, sentence-aware, 10% overlap), embed in batches of 10-20
4. Progress updates as each batch completes
5. On completion: EmbeddingProgress card dismissed, chat input becomes active
6. If book was already embedded (checked via `isBookEmbedded`): skip, show chat immediately

### Ask Question Flow

1. User types question in ChatInput, taps send
2. User message appears immediately in message list (right-aligned bubble)
3. Assistant typing indicator appears (three-dot animation in assistant bubble)
4. Behind the scenes: query embedded on-device, top 5 chunks retrieved via sqlite-vec, chunks + conversation history sent to Worker `/api/text/completions`
5. Response received: typing indicator replaced with assistant message bubble
6. Source references (if any) appear as tappable chips below the assistant message
7. Message saved to local SQLite (conversations + messages tables), marked isDirty for sync

### Source Reference Tap

1. User taps a source reference chip on an assistant message
2. App navigates to the reader screen for the book at the referenced location
3. For EPUB: `goToLocation(cfiRange)` -- opens book at the exact passage
4. For PDF: navigates to the referenced page number

### Multi-Turn Conversation

1. Previous messages are visible in scrollable list above input
2. Each new question includes last N messages as context to the LLM (token budget managed server-side)
3. Conversation persists across app restarts via local SQLite storage
4. Conversation syncs to other devices via existing push/pull engine (append-only merge)

### New Conversation

1. From conversations list: tap [+] button
2. Bottom sheet shows list of embedded books (books that have completed the embedding pipeline)
3. User taps a book to start a new conversation
4. Navigates to `chat/[bookId]` with empty conversation state
5. If book is not yet embedded, embedding flow begins on the chat screen

### Delete Conversation

1. User long-presses a conversation row in the conversations list
2. `Alert.alert` confirmation dialog appears
3. On confirm: conversation soft-deleted (isDeleted = 1), marked isDirty, removed from list
4. Sync propagates deletion to other devices

### Reader to Chat Navigation

1. User is reading a book in the EPUB or PDF reader
2. User taps the AI/chat icon in ReaderToolbar
3. App navigates to `chat/[bookId]` for the current book
4. If no conversation exists, one is created automatically
5. If book is not embedded, embedding flow begins

---

## Data Model (New Tables)

### conversations table

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID, client-generated via expo-crypto |
| bookId | TEXT NOT NULL | FK to books.id |
| userId | TEXT | null on mobile, set by server |
| title | TEXT | Auto-generated from first user message (first 50 chars) |
| createdAt | INTEGER NOT NULL | Unix timestamp ms |
| updatedAt | INTEGER NOT NULL | Unix timestamp ms |
| syncVersion | INTEGER DEFAULT 0 | Server-assigned monotonic counter |
| isDirty | INTEGER DEFAULT 1 | Needs push |
| isDeleted | INTEGER DEFAULT 0 | Soft delete for sync |

### messages table

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID, client-generated via expo-crypto |
| conversationId | TEXT NOT NULL | FK to conversations.id |
| role | TEXT NOT NULL | "user" or "assistant" |
| content | TEXT NOT NULL | Message text |
| sourceChunks | TEXT | JSON array of { chunkId, text, chapter, cfiRange } for assistant messages |
| createdAt | INTEGER NOT NULL | Unix timestamp ms |
| updatedAt | INTEGER NOT NULL | Unix timestamp ms |
| syncVersion | INTEGER DEFAULT 0 | Server-assigned monotonic counter |
| isDirty | INTEGER DEFAULT 1 | Needs push |
| isDeleted | INTEGER DEFAULT 0 | Soft delete for sync |

### chunks table (local only, not synced)

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID |
| bookId | TEXT NOT NULL | FK to books.id |
| chunkIndex | INTEGER NOT NULL | Position in book |
| text | TEXT NOT NULL | Chunk content |
| chapter | TEXT | Chapter/section label |
| createdAt | INTEGER NOT NULL | Unix timestamp ms |

### chunk_vectors virtual table (local only, not synced)

| Column | Type | Notes |
|--------|------|-------|
| rowid | INTEGER | Links to chunks table rowid |
| embedding | float[384] | 384-dimension vector from all-MiniLM-L6-v2 |

---

## Copywriting

### Primary CTA
- "Ask about this book" -- placeholder text in ChatInput
- "Download Model" -- button on ModelDownloadCard for first-time model download

### Empty States
- Conversations list with no conversations: Icon `message` (SF Symbol) at 40px, gray-400. Title: "No conversations yet". Body: "Open a book and tap the AI icon to start a conversation."
- Chat screen with no messages (after embedding): Icon `sparkles` (SF Symbol) at 40px, gray-400. Title: "Ask anything about this book". Body: "Ask questions about characters, themes, or anything you want to understand better."
- Chat screen book not embedded and model ready: EmbeddingProgress card appears automatically (no empty state text needed)

### Error States
- LLM request failure: Inline error message in assistant bubble position: "Could not get a response. Check your connection and try again." with a "Retry" text button (accent color).
- Embedding failure: EmbeddingProgress card shows: "Embedding failed. Tap to retry." with tap-to-retry action.
- Model download failure: ModelDownloadCard shows: "Download failed. Check your connection and try again." with "Retry Download" button replacing the original download button.

### Destructive Actions
- Delete conversation: `Alert.alert("Delete Conversation", "This conversation will be removed from all your devices.", [Cancel, Delete])` -- "Delete" button uses destructive style.

### Labels
- ReaderToolbar AI button: accessibilityLabel "Ask AI about this book"
- ChatInput send button: accessibilityLabel "Send message"
- ChatInput stop button: accessibilityLabel "Stop generating"
- Source reference chips: accessibilityLabel "View source: {chapter label}"
- ModelDownloadCard button: accessibilityLabel "Download AI model, 80 megabytes"
- Conversations list [+] button: accessibilityLabel "New conversation"
- Chat tab: title "Chat"

---

## Accessibility

- All touch targets: 44x44px minimum (existing pattern)
- Message bubbles: accessibilityRole "text", content as accessibilityLabel
- Source reference chips: accessibilityRole "button"
- Chat input: accessibilityLabel "Message input", accessibilityHint "Type a question about this book"
- Assistant typing indicator: accessibilityLabel "AI is thinking"
- EmbeddingProgress: accessibilityLabel "Preparing book for AI, {percent} percent complete"
- ModelDownloadCard: accessibilityRole "alert" when download is required
- Color contrast: user bubbles (white on accent #0a7ea4) meet WCAG AA at 4.5:1. Assistant bubbles use primary text on gray-100/dark surface.

---

## Animation

| Element | Enter | Exit | Duration |
|---------|-------|------|----------|
| ChatMessage (user) | FadeIn + SlideInRight | -- | 200ms |
| ChatMessage (assistant) | FadeIn + SlideInLeft | -- | 200ms |
| Typing indicator | FadeIn, dots pulse (opacity 0.3 to 1.0 loop) | FadeOut | 150ms enter, 600ms pulse cycle |
| EmbeddingProgress | FadeIn | FadeOut | 200ms |
| ModelDownloadCard | FadeIn | FadeOut | 200ms |
| Source reference chips | FadeIn (staggered, 50ms delay per chip) | -- | 150ms each |
| Send button state change | -- (instant color swap) | -- | 0ms |

---

## Registry

**Tool:** NativeWind (not shadcn -- React Native project)
**Third-party registries:** none
**Third-party blocks:** none

No registry safety gate required.

---

## Checker Sign-Off

- [ ] Dimension 1 Copywriting: PASS
- [ ] Dimension 2 Visuals: PASS
- [ ] Dimension 3 Color: PASS
- [ ] Dimension 4 Typography: PASS
- [ ] Dimension 5 Spacing: PASS
- [ ] Dimension 6 Registry Safety: PASS

**Approval:** pending

---

## Pre-populated Sources

| Source | Decisions Used |
|--------|---------------|
| REQUIREMENTS.md | RAG-01 through RAG-08, CONV-01 through CONV-04 requirements |
| ROADMAP.md | Phase 6 success criteria, dependencies on Phase 2/3/4 |
| 06-RESEARCH.md | Standard stack (react-native-executorch, sqlite-vec), architecture patterns (chunking, embedding pipeline, RAG query flow, conversation sync), data model (chunks, conversations, messages tables) |
| STATE.md | Accumulated decisions (sync patterns: LWW, isDirty, syncVersion, append-only), blocker note on ~80MB model download UX |
| 05-UI-SPEC.md | Design system continuity (NativeWind, Colors constant, spacing scale, typography weights, touch targets, animation patterns, BottomSheet patterns) |
| Existing codebase | Tab layout structure, Colors/Fonts constants, IconSymbol wrapper, ReaderToolbar pattern, existing component naming conventions |

---
*Generated: 2026-04-06 | Revised: 2026-04-06*
