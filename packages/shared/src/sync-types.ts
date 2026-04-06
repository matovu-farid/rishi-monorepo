export interface PushRequest {
  changes: {
    books: Array<Record<string, unknown>>;
    highlights?: Array<Record<string, unknown>>;
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
  };
  syncVersion: number;
}

export interface UploadUrlRequest {
  fileHash: string;
  contentType: string;
}

export interface UploadUrlResponse {
  uploadUrl?: string;
  r2Key: string;
  exists: boolean;
  expiresIn?: number;
}

export interface DownloadUrlRequest {
  r2Key: string;
}

export interface DownloadUrlResponse {
  downloadUrl: string;
  expiresIn: number;
}
