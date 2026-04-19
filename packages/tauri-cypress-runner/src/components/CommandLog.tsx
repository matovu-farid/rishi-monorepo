import { useCommandStore } from "../stores/commandStore";
import type { CommandEntry } from "../types";

function CmdStatusIcon({ status }: { status: CommandEntry["status"] }) {
  switch (status) {
    case "passed": return <span className="text-success text-[10px]">&#10003;</span>;
    case "failed": return <span className="text-error text-[10px]">&#10007;</span>;
    case "running": return <span className="text-accent text-[10px] animate-pulse">&#9679;</span>;
    default: return <span className="text-text-muted text-[10px]">&#9679;</span>;
  }
}

function formatDuration(ms?: number): string {
  if (ms == null) return "";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

interface CommandLogProps {
  onActivateTimeTravel: (snapshotIndex: number) => void;
}

export function CommandLog({ onActivateTimeTravel }: CommandLogProps) {
  const { entries, selectedIndex, selectEntry } = useCommandStore();

  if (entries.length === 0) {
    return (
      <div className="p-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">Command Log</div>
        <div className="text-text-muted text-xs">Run a test to see commands</div>
      </div>
    );
  }

  return (
    <div className="p-2">
      <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">
        Command Log ({entries.length})
      </div>
      <ol className="space-y-0.5">
        {entries.map((entry, i) => (
          <li key={i}>
            <button
              onClick={() => {
                selectEntry(i);
                if (entry.snapshotIndex >= 0) {
                  onActivateTimeTravel(entry.snapshotIndex);
                }
              }}
              className={`w-full text-left flex items-center gap-1.5 px-1.5 py-1 rounded text-xs transition-colors ${
                selectedIndex === i
                  ? "bg-accent/20 text-accent"
                  : "text-text hover:bg-white/5"
              }`}
            >
              <CmdStatusIcon status={entry.status} />
              <span className="truncate flex-1 font-mono">{entry.name}</span>
              {entry.snapshotIndex >= 0 && (
                <span className="text-text-muted text-[9px] shrink-0" title="Has snapshot">&#128247;</span>
              )}
              {entry.duration != null && (
                <span className="text-text-muted text-[10px] shrink-0">{formatDuration(entry.duration)}</span>
              )}
            </button>
            {entry.error && selectedIndex === i && (
              <div className="ml-5 mt-0.5 text-[10px] text-error bg-error/10 rounded px-1.5 py-1 break-all">
                {entry.error}
              </div>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}
