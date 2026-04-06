import { useState, useEffect } from 'react';
import { Check, Loader2, AlertTriangle, CloudOff, RefreshCw } from 'lucide-react';
import { onSyncStatusChange, triggerSync, type SyncStatus } from '../modules/sync-triggers';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from './components/ui/tooltip';

function formatRelativeTime(timestamp: number | null): string {
  if (!timestamp) return 'Never synced';
  const seconds = Math.floor((Date.now() - timestamp) / 1000);
  if (seconds < 60) return 'Just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

const STATUS_CONFIG: Record<SyncStatus, {
  icon: typeof Check;
  label: string;
  animate?: boolean;
  clickable: boolean;
}> = {
  'not-synced': { icon: RefreshCw, label: 'Not synced', clickable: true },
  'syncing': { icon: Loader2, label: 'Syncing...', animate: true, clickable: false },
  'synced': { icon: Check, label: 'Synced', clickable: true },
  'error': { icon: AlertTriangle, label: 'Sync failed', clickable: true },
  'offline': { icon: CloudOff, label: 'Offline', clickable: false },
};

export function SyncStatusIndicator() {
  const [status, setStatus] = useState<SyncStatus>('not-synced');
  const [lastSyncAt, setLastSyncAt] = useState<number | null>(null);

  useEffect(() => {
    const unsubscribe = onSyncStatusChange((newStatus, newLastSyncAt) => {
      setStatus(newStatus);
      setLastSyncAt(newLastSyncAt);
    });
    return unsubscribe;
  }, []);

  const config = STATUS_CONFIG[status];
  const Icon = config.icon;

  const handleClick = () => {
    if (config.clickable) {
      triggerSync();
    }
  };

  return (
    <TooltipProvider>
      <Tooltip>
        <TooltipTrigger asChild>
          <button
            onClick={handleClick}
            disabled={!config.clickable}
            className="flex items-center gap-2 px-3 py-2 rounded-md w-full min-h-[32px] hover:bg-sidebar-accent transition-colors disabled:opacity-50 disabled:cursor-default"
          >
            <Icon
              size={16}
              className={config.animate ? 'animate-spin' : ''}
            />
            <span className="text-xs font-medium text-sidebar-foreground/60">
              {config.label}
            </span>
          </button>
        </TooltipTrigger>
        <TooltipContent side="right">
          <p>Last synced: {formatRelativeTime(lastSyncAt)}</p>
        </TooltipContent>
      </Tooltip>
    </TooltipProvider>
  );
}
