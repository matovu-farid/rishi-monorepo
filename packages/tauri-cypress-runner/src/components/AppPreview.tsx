import { useSnapshotStore } from "../stores/snapshotStore";

interface AppPreviewProps {
  timeTravelActive: boolean;
  timeTravelIndex: number;
  timeTravelMax: number;
  onPrev: () => void;
  onNext: () => void;
  onDeactivate: () => void;
}

export function AppPreview({
  timeTravelActive,
  timeTravelIndex,
  timeTravelMax,
  onPrev,
  onNext,
  onDeactivate,
}: AppPreviewProps) {
  const { snapshots, viewMode, setViewMode } = useSnapshotStore();

  const snapshot = timeTravelActive
    ? snapshots[timeTravelIndex] ?? null
    : snapshots.length > 0
      ? snapshots[snapshots.length - 1]
      : null;

  if (!snapshot) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="text-center">
          <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">App Preview</div>
          <div className="text-text-muted text-xs">Run a test to see preview</div>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      <div className="flex items-center justify-between px-2 py-1 border-b border-border">
        <div className="flex items-center gap-2">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">
            {snapshot.label || "App Preview"}
          </span>
          {timeTravelActive && (
            <span className="text-[9px] text-accent">
              {timeTravelIndex + 1}/{timeTravelMax + 1}
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {timeTravelActive && (
            <>
              <button onClick={onPrev} disabled={timeTravelIndex <= 0} className="text-[10px] text-text-muted hover:text-text disabled:opacity-30">
                &#9664;
              </button>
              <button onClick={onNext} disabled={timeTravelIndex >= timeTravelMax} className="text-[10px] text-text-muted hover:text-text disabled:opacity-30">
                &#9654;
              </button>
              <button onClick={onDeactivate} className="text-[9px] text-text-muted hover:text-text">
                &#10005; Exit
              </button>
            </>
          )}
          <button
            onClick={() => setViewMode(viewMode === "screenshot" ? "html" : "screenshot")}
            className="text-[9px] text-text-muted hover:text-accent"
          >
            {viewMode === "screenshot" ? "HTML" : "Screenshot"}
          </button>
          <span className="text-[9px] text-text-muted">{snapshot.url}</span>
        </div>
      </div>

      {viewMode === "screenshot" && snapshot.screenshot ? (
        <div className="flex-1 overflow-auto flex items-center justify-center bg-black/20 p-2">
          <img
            src={snapshot.screenshot}
            alt="App screenshot"
            className="max-w-full max-h-full object-contain rounded shadow-lg"
          />
        </div>
      ) : (
        <div className="flex-1 overflow-auto">
          <iframe
            srcDoc={snapshot.html}
            title="App snapshot"
            className="w-full h-full border-none bg-white"
            sandbox="allow-same-origin"
          />
        </div>
      )}
    </div>
  );
}
