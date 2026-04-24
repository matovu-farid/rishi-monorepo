import { useMemo } from "react";
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
  const { snapshots, viewMode, setViewMode, hoverPreviewIndex } =
    useSnapshotStore();

  // Determine which snapshot to show:
  // 1. If hovering over a command with snapshot, show that (temporary preview)
  // 2. If time-travel is active, show the time-travel snapshot
  // 3. Auto-show the latest snapshot (don't require manual activation)
  const snapshot = useMemo(() => {
    if (hoverPreviewIndex != null && snapshots[hoverPreviewIndex]) {
      return snapshots[hoverPreviewIndex];
    }
    if (timeTravelActive && snapshots[timeTravelIndex]) {
      return snapshots[timeTravelIndex];
    }
    if (snapshots.length > 0) {
      return snapshots[snapshots.length - 1];
    }
    return null;
  }, [hoverPreviewIndex, timeTravelActive, timeTravelIndex, snapshots]);

  const isHoverPreview = hoverPreviewIndex != null;
  const activeIndex =
    hoverPreviewIndex ?? (timeTravelActive ? timeTravelIndex : snapshots.length - 1);

  if (!snapshot) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="text-center">
          <div className="text-3xl text-text-muted/30 mb-3">&#128270;</div>
          <div className="text-[9px] uppercase text-text-muted tracking-wider mb-1">
            App Preview
          </div>
          <div className="text-text-muted text-xs">
            Run a test to see preview
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      {/* Header bar */}
      <div className="flex items-center justify-between px-2 py-1 border-b border-border shrink-0">
        <div className="flex items-center gap-2">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">
            {snapshot.label || "App Preview"}
          </span>
          {isHoverPreview && (
            <span className="text-[9px] text-warning bg-warning/10 rounded px-1.5 py-0.5">
              Preview
            </span>
          )}
          {timeTravelActive && !isHoverPreview && (
            <span className="text-[9px] text-accent bg-accent/10 rounded px-1.5 py-0.5">
              {timeTravelIndex + 1}/{timeTravelMax + 1}
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {timeTravelActive && !isHoverPreview && (
            <>
              <button
                onClick={onPrev}
                disabled={timeTravelIndex <= 0}
                className="text-[10px] text-text-muted hover:text-text disabled:opacity-30 px-1"
              >
                &#9664;
              </button>
              <button
                onClick={onNext}
                disabled={timeTravelIndex >= timeTravelMax}
                className="text-[10px] text-text-muted hover:text-text disabled:opacity-30 px-1"
              >
                &#9654;
              </button>
              <button
                onClick={onDeactivate}
                className="text-[9px] text-text-muted hover:text-text px-1"
              >
                &#10005; Exit
              </button>
            </>
          )}

          {/* Snapshot count indicator */}
          {snapshots.length > 0 && (
            <span className="text-[9px] text-text-muted bg-surface rounded px-1.5 py-0.5">
              &#128247; {snapshots.length}
            </span>
          )}

          <button
            onClick={() =>
              setViewMode(viewMode === "screenshot" ? "html" : "screenshot")
            }
            className="text-[9px] text-text-muted hover:text-accent px-1"
          >
            {viewMode === "screenshot" ? "HTML" : "Screenshot"}
          </button>

          {/* Viewport dimensions */}
          <span className="text-[9px] text-text-muted/60 tabular-nums">
            {snapshot.url}
          </span>
        </div>
      </div>

      {/* Main preview area */}
      <div className="flex-1 overflow-auto relative">
        {viewMode === "screenshot" && snapshot.screenshot ? (
          <div className="h-full flex items-center justify-center bg-black/20 p-2">
            <img
              src={snapshot.screenshot}
              alt="App screenshot"
              className="max-w-full max-h-full object-contain rounded shadow-lg"
            />
          </div>
        ) : (
          <iframe
            srcDoc={snapshot.html}
            title="App snapshot"
            className="w-full h-full border-none bg-white"
            sandbox="allow-same-origin"
          />
        )}
      </div>

      {/* Snapshot thumbnail strip */}
      {snapshots.length > 1 && (
        <div className="border-t border-border shrink-0 bg-surface">
          <div className="flex items-center gap-1 p-1 overflow-x-auto">
            {snapshots.map((snap, index) => {
              const isActive = index === activeIndex;
              return (
                <button
                  key={index}
                  onClick={() => {
                    // Clicking a thumbnail activates time-travel at that index
                    if (snap.screenshot) {
                      // Use window to trigger time-travel (the parent handles this via onActivateTimeTravel)
                      // For now, just show the snapshot via hover mechanism
                      useSnapshotStore
                        .getState()
                        .setHoverPreviewIndex(index);
                    }
                  }}
                  onMouseLeave={() => {
                    // Only clear if we set it via this thumbnail
                    if (hoverPreviewIndex === index) {
                      useSnapshotStore
                        .getState()
                        .setHoverPreviewIndex(null);
                    }
                  }}
                  className={`shrink-0 rounded overflow-hidden transition-all ${
                    isActive
                      ? "ring-1 ring-accent ring-offset-1 ring-offset-surface"
                      : "opacity-60 hover:opacity-100"
                  }`}
                  title={snap.label || `Snapshot ${index + 1}`}
                >
                  {snap.screenshot ? (
                    <img
                      src={snap.screenshot}
                      alt={snap.label || `Snapshot ${index + 1}`}
                      className="w-12 h-8 object-cover"
                    />
                  ) : (
                    <div className="w-12 h-8 bg-panel-bg flex items-center justify-center text-[8px] text-text-muted">
                      {index + 1}
                    </div>
                  )}
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
