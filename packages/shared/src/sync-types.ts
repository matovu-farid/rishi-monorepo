export interface PushRequest {
  changes: {
    books: Array<Record<string, unknown>>;
    highlights?: Array<Record<string, unknown>>;
    conversations?: Array<Record<string, unknown>>;
    messages?: Array<Record<string, unknown>>;
  };
}

export interface PushResponse {
  conflicts: Array<Record<string, unknown>>;
  syncVersion: number;
}

export interface PullResponse {
  changes: {
    books: Array<Record<string, unknown>>;
    highlights?: Array<Record<string, unknown>>;
    conversations?: Array<Record<string, unknown>>;
    messages?: Array<Record<string, unknown>>;
  };
  syncVersion: number;
  hasMore?: boolean;
}

export interface UploadUrlRequest {
  fileHash: string;
  contentType: string;
  // Size in bytes of the file the client intends to upload. Required so the
  // worker can enforce per-file and per-user storage caps before issuing a
  // presigned PUT URL.
  fileSize: number;
}

export interface UploadUrlResponse {
  uploadUrl?: string;
  r2Key: string;
  exists: boolean;
  expiresIn?: number;
}

// Typed error shape the worker returns when /upload-url denies the request
// because the user is over (or would go over) one of the storage caps.
// Clients should switch on `code` to render a localized message.
export interface UploadUrlError {
  error: string;
  code: 'FILE_TOO_LARGE' | 'BOOK_LIMIT_REACHED' | 'STORAGE_LIMIT_REACHED';
  limit: number;
  current?: number;
}

export interface DownloadUrlRequest {
  r2Key: string;
}

export interface DownloadUrlResponse {
  downloadUrl: string;
  expiresIn: number;
}
