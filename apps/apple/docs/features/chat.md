# Chat

[Back to contributor README](../README.md)

## What it does

Chat is the text conversation surface. The user opens it from inside a
book; the assistant streams its reply token by token. Past conversations
live in a "Conversations" tab where the user can search, reopen, or
delete them. Conversations are scoped per book — Book A and Book B give
two separate threads.

## The user flow

- While reading, tap the chat button. A sheet slides up scoped to the
  current book.
- Type a question. Send.
- The assistant's reply streams in word by word. The user can scroll
  while it streams.
- Close the sheet. The conversation is saved.
- Open the Conversations tab to see every past chat. Tap to re-open;
  swipe to delete.

## Where it lives

| Role | File |
| --- | --- |
| Entry point sheet | `Packages/RishiChat/Sources/RishiChat/UI/ChatPanelView.swift` |
| Chat panel view model | `Packages/RishiChat/Sources/RishiChat/UI/ChatPanelViewModel.swift` |
| Conversations list view | `Packages/RishiChat/Sources/RishiChat/UI/ConversationsListView.swift` |
| Conversations list view model | `Packages/RishiChat/Sources/RishiChat/UI/ConversationsListViewModel.swift` |
| Chat service (actor) | `Packages/RishiChat/Sources/RishiChat/Service/ChatService.swift` |
| SSE parser | `Packages/RishiChat/Sources/RishiChat/Service/SSEParser.swift` |
| Server endpoint | `Packages/RishiChat/Sources/RishiChat/Service/ChatStreamEndpoint.swift` |
| Persistence | `ConversationStore`, `MessageStore` from `RishiDB` |

## What it depends on

- `RishiCore` — `Conversation`, `Message`, `UserID`, `BookID`, and the
  `ChatService` protocol shape.
- `RishiAPI` — `WorkerClient` for the streaming request to the
  Cloudflare Worker's `/api/chat` endpoint.
- `RishiDB` — conversation and message stores.
- `RishiUIKit`, `RishiLogging` for tokens and breadcrumbs.

It does not depend on `RishiReader`. The reader presents the sheet via
a small protocol seam wired in the app's composition root.

## Why it's built this way

- The service is an `actor` because there is one in-flight turn at a
  time per panel; actor isolation enforces that without a lock.
- Streaming uses server-sent events (the worker writes `data:
  {...}\n\n` frames; `SSEParser` turns them into typed events). SSE
  was chosen over WebSockets because the stream is one-way once the
  request goes out, and SSE is simpler over HTTP/2.
- Cancellation is end-to-end. Closing the sheet cancels the consuming
  `Task`, which cancels the inner `WorkerClient.stream`, which cancels
  the underlying `URLSessionDataTask`. Whatever the assistant produced
  so far is persisted as a partial message so sync does not drop it.
- The dirty hook (`ChatDirtyHook`) is optional and is wired at the app
  layer to the sync engine. The chat package does not import the sync
  package; it just emits "this conversation changed" events.

## Gotchas

- The conversation list reads from the local `ConversationStore`.
  Newly-synced conversations appear only after the sync engine applies
  inbound changes — the chat package never polls the worker itself.
- Embeddings and retrieval-augmented generation happen on the worker.
  There is no on-device vector store; do not add one without
  coordinating with the worker team.

---

**Next:** [voice.md](voice.md) — real-time voice conversation.
