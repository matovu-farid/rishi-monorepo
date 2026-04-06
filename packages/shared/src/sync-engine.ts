import type { SyncDbAdapter } from "./sync-adapter";
import type { PushResponse, PullResponse } from "./sync-types";

export interface SyncEngineConfig {
  adapter: SyncDbAdapter;
  apiFetch: (path: string, init?: RequestInit) => Promise<Response>;
}

export interface SyncEngine {
  sync(): Promise<void>;
  push(): Promise<void>;
  pull(): Promise<void>;
}

export function createSyncEngine(config: SyncEngineConfig): SyncEngine {
  let isSyncing = false;

  async function push(): Promise<void> {
    const [dirtyBooks, dirtyHighlights, dirtyConversations, dirtyMessages] =
      await Promise.all([
        config.adapter.getDirtyBooks(),
        config.adapter.getDirtyHighlights(),
        config.adapter.getDirtyConversations(),
        config.adapter.getDirtyMessages(),
      ]);

    if (
      dirtyBooks.length === 0 &&
      dirtyHighlights.length === 0 &&
      dirtyConversations.length === 0 &&
      dirtyMessages.length === 0
    )
      return;

    const response = await config.apiFetch("/api/sync/push", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        changes: {
          books: dirtyBooks,
          highlights: dirtyHighlights,
          conversations: dirtyConversations,
          messages: dirtyMessages,
        },
      }),
    });

    if (!response.ok) {
      console.warn("[sync:push] server responded", response.status);
      return;
    }

    const data: PushResponse = await response.json();

    // Apply conflict resolutions from server
    for (const conflict of data.conflicts) {
      const c = conflict as Record<string, unknown>;
      if (typeof c.id !== "string") continue;

      if ("cfiRange" in c) {
        await config.adapter.applyHighlightConflict(c, data.syncVersion);
      } else if ("title" in c && "bookId" in c && !("filePath" in c)) {
        await config.adapter.applyConversationConflict(c, data.syncVersion);
      } else {
        await config.adapter.applyBookConflict(c, data.syncVersion);
      }
    }

    // Mark pushed records clean
    await config.adapter.markBooksClean(
      dirtyBooks.map((b) => b.id),
      data.syncVersion,
    );
    await config.adapter.markHighlightsClean(
      dirtyHighlights.map((h) => h.id),
      data.syncVersion,
    );
    await config.adapter.markConversationsClean(
      dirtyConversations.map((c) => c.id),
      data.syncVersion,
    );
    await config.adapter.markMessagesClean(
      dirtyMessages.map((m) => m.id),
      data.syncVersion,
    );
  }

  async function pull(): Promise<void> {
    const lastVersion = await config.adapter.getLastSyncVersion();

    const response = await config.apiFetch(
      `/api/sync/pull?since_version=${lastVersion}`,
      {
        method: "GET",
      },
    );

    if (!response.ok) {
      console.warn("[sync:pull] server responded", response.status);
      return;
    }

    const data: PullResponse = await response.json();

    for (const remote of data.changes.books) {
      await config.adapter.upsertRemoteBook(remote);
    }
    for (const remote of data.changes.highlights ?? []) {
      await config.adapter.upsertRemoteHighlight(remote);
    }
    for (const remote of data.changes.conversations ?? []) {
      await config.adapter.upsertRemoteConversation(remote);
    }
    for (const remote of data.changes.messages ?? []) {
      await config.adapter.insertRemoteMessage(remote);
    }

    await config.adapter.updateLastSyncVersion(data.syncVersion);
  }

  return {
    async sync() {
      if (isSyncing) return;
      isSyncing = true;
      try {
        await push();
        await pull();
      } catch (error) {
        console.warn("[sync] cycle failed:", error);
      } finally {
        isSyncing = false;
      }
    },
    push,
    pull,
  };
}
