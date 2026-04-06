// Sync record types -- platform-agnostic representations

export interface SyncBook {
  id: string; // UUID (mobile: books.id, desktop: books.sync_id)
  title: string;
  author: string;
  format: string;
  currentCfi: string | null;
  currentPage: number | null;
  fileHash: string | null;
  fileR2Key: string | null;
  coverR2Key: string | null;
  createdAt: number; // Unix timestamp ms
  updatedAt: number;
  syncVersion: number;
  isDirty: boolean;
  isDeleted: boolean;
}

export interface SyncHighlight {
  id: string;
  bookId: string; // UUID of book
  cfiRange: string;
  text: string;
  color: string;
  note: string | null;
  chapter: string | null;
  createdAt: number;
  updatedAt: number;
  syncVersion: number;
  isDirty: boolean;
  isDeleted: boolean;
}

export interface SyncConversation {
  id: string;
  bookId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  syncVersion: number;
  isDirty: boolean;
  isDeleted: boolean;
}

export interface SyncMessage {
  id: string;
  conversationId: string;
  role: string;
  content: string;
  sourceChunks: string | null;
  createdAt: number;
  updatedAt: number;
  syncVersion: number;
  isDirty: boolean;
  isDeleted: boolean;
}

export interface SyncDbAdapter {
  // Push: get dirty records
  getDirtyBooks(): Promise<SyncBook[]>;
  getDirtyHighlights(): Promise<SyncHighlight[]>;
  getDirtyConversations(): Promise<SyncConversation[]>;
  getDirtyMessages(): Promise<SyncMessage[]>;
  getLastSyncVersion(): Promise<number>;

  // Push: handle conflicts from server
  applyBookConflict(
    conflict: Record<string, unknown>,
    syncVersion: number,
  ): Promise<void>;
  applyHighlightConflict(
    conflict: Record<string, unknown>,
    syncVersion: number,
  ): Promise<void>;
  applyConversationConflict(
    conflict: Record<string, unknown>,
    syncVersion: number,
  ): Promise<void>;

  // Push: mark pushed records clean
  markBooksClean(ids: string[], syncVersion: number): Promise<void>;
  markHighlightsClean(ids: string[], syncVersion: number): Promise<void>;
  markConversationsClean(ids: string[], syncVersion: number): Promise<void>;
  markMessagesClean(ids: string[], syncVersion: number): Promise<void>;

  // Pull: apply remote records
  upsertRemoteBook(remote: Record<string, unknown>): Promise<void>;
  upsertRemoteHighlight(remote: Record<string, unknown>): Promise<void>;
  upsertRemoteConversation(remote: Record<string, unknown>): Promise<void>;
  insertRemoteMessage(remote: Record<string, unknown>): Promise<void>;
  updateLastSyncVersion(version: number): Promise<void>;
}
