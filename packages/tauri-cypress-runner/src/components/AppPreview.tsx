import { useSnapshotStore } from "../stores/snapshotStore";

export function AppPreview() {
  const { snapshots, viewMode } = useSnapshotStore();
  const latest = snapshots.length > 0 ? snapshots[snapshots.length - 1] : null;

  if (!latest) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="text-center">
          <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">App Preview</div>
          <div className="text-text-muted text-xs">Run a test to see preview</div>
        </div>
      </div>
    );
  }

  if (viewMode === "screenshot" && latest.screenshot) {
    return (
      <div className="h-full flex flex-col">
        <div className="flex items-center justify-between px-2 py-1 border-b border-border">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">
            {latest.label || "App Preview"}
          </span>
          <span className="text-[9px] text-text-muted">{latest.url}</span>
        </div>
        <div className="flex-1 overflow-auto flex items-center justify-center bg-black/20 p-2">
          <img
            src={latest.screenshot}
            alt="App screenshot"
            className="max-w-full max-h-full object-contain rounded shadow-lg"
          />
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      <div className="flex items-center justify-between px-2 py-1 border-b border-border">
        <span className="text-[9px] uppercase text-text-muted tracking-wider">
          {latest.label || "App Preview"} (HTML)
        </span>
        <span className="text-[9px] text-text-muted">{latest.url}</span>
      </div>
      <div className="flex-1 overflow-auto">
        <iframe
          srcDoc={latest.html}
          title="App snapshot"
          className="w-full h-full border-none bg-white"
          sandbox="allow-same-origin"
        />
      </div>
    </div>
  );
}
