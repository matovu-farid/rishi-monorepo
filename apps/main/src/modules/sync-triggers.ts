import { createSyncEngine, type SyncEngine } from '@rishi/shared/sync-engine';
import { DesktopSyncAdapter } from './sync-adapter';
import { getAuthToken } from './auth';

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev';
const SYNC_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

export type SyncStatus = 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline';

type SyncStatusListener = (status: SyncStatus, lastSyncAt: number | null) => void;

let engine: SyncEngine | null = null;
let syncStatus: SyncStatus = 'not-synced';
let lastSyncAt: number | null = null;
let intervalId: ReturnType<typeof setInterval> | null = null;
const listeners: Set<SyncStatusListener> = new Set();

function notifyListeners() {
  for (const listener of listeners) {
    listener(syncStatus, lastSyncAt);
  }
}

export function onSyncStatusChange(listener: SyncStatusListener): () => void {
  listeners.add(listener);
  // Immediately call with current state
  listener(syncStatus, lastSyncAt);
  return () => listeners.delete(listener);
}

export function getSyncStatus(): { status: SyncStatus; lastSyncAt: number | null } {
  return { status: syncStatus, lastSyncAt };
}

async function apiFetch(path: string, init?: RequestInit): Promise<Response> {
  const token = await getAuthToken();

  const headers: Record<string, string> = {
    ...init?.headers as Record<string, string>,
    'Content-Type': 'application/json',
  };

  if (token === "dev-placeholder-token") {
    const secret = import.meta.env.VITE_DEV_BYPASS_SECRET;
    if (secret) {
      headers['X-Dev-Bypass'] = secret;
    } else {
      // No bypass secret configured — skip the request silently
      return new Response(JSON.stringify({ error: "Not authenticated (dev)" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }
  } else {
    headers['Authorization'] = `Bearer ${token}`;
  }

  return fetch(`${WORKER_URL}${path}`, {
    ...init,
    headers,
  });
}

export async function triggerSync(): Promise<void> {
  if (!engine) return;
  if (syncStatus === 'syncing') return;

  syncStatus = 'syncing';
  notifyListeners();

  try {
    await engine.sync();
    syncStatus = 'synced';
    lastSyncAt = Date.now();
  } catch (error) {
    console.warn('[desktop-sync] sync failed:', error);
    // Check if offline
    if (!navigator.onLine) {
      syncStatus = 'offline';
    } else {
      syncStatus = 'error';
    }
  }

  notifyListeners();
}

export function initDesktopSync(): void {
  if (engine) return; // already initialized

  const adapter = new DesktopSyncAdapter();
  engine = createSyncEngine({ adapter, apiFetch });

  // Sync on app focus
  window.addEventListener('focus', () => {
    void triggerSync();
  });

  // Online/offline detection
  window.addEventListener('online', () => {
    if (syncStatus === 'offline') {
      void triggerSync();
    }
  });
  window.addEventListener('offline', () => {
    syncStatus = 'offline';
    notifyListeners();
  });

  // Periodic sync every 5 minutes
  intervalId = setInterval(() => {
    if (navigator.onLine) {
      void triggerSync();
    }
  }, SYNC_INTERVAL_MS);

  // Initial sync
  void triggerSync();
}

export function destroyDesktopSync(): void {
  if (intervalId) {
    clearInterval(intervalId);
    intervalId = null;
  }
  engine = null;
}

/**
 * Debounced sync trigger for local writes.
 * Fires triggerSync() 2 seconds after the last write, coalescing rapid writes.
 */
let writeTimeout: ReturnType<typeof setTimeout> | null = null;
export function triggerSyncOnWrite(): void {
  if (writeTimeout) clearTimeout(writeTimeout);
  writeTimeout = setTimeout(() => {
    void triggerSync();
  }, 2000);
}
