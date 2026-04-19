import { useTestStore } from "../stores/testStore";

interface StatusBarProps {
  connectionState: "disconnected" | "connecting" | "connected" | "error";
  executionState: string;
  onRun: () => void;
  onStop: () => void;
}

const CONNECTION_COLORS: Record<string, string> = {
  disconnected: "bg-text-muted",
  connecting: "bg-warning animate-pulse",
  connected: "bg-success",
  error: "bg-error",
};

const CONNECTION_LABELS: Record<string, string> = {
  disconnected: "Disconnected",
  connecting: "Connecting...",
  connected: "Connected",
  error: "Error",
};

export function StatusBar({ connectionState, executionState, onRun, onStop }: StatusBarProps) {
  const { files, results } = useTestStore();
  const resultValues = Object.values(results);
  const passed = resultValues.filter((r) => r.status === "passed").length;
  const failed = resultValues.filter((r) => r.status === "failed").length;
  const total = files.length;
  const isRunning = executionState === "building" || executionState === "launching" || executionState === "connecting" || executionState === "running";

  return (
    <div className="h-6 bg-panel-bg border-t border-border flex items-center px-3 text-[11px] gap-4">
      <div className="flex items-center gap-1.5">
        <div className={`w-2 h-2 rounded-full ${CONNECTION_COLORS[connectionState]}`} />
        <span className="text-text-muted">{CONNECTION_LABELS[connectionState]}</span>
      </div>

      {total > 0 && (
        <div className="flex items-center gap-2">
          {passed > 0 && <span className="text-success">{passed} passed</span>}
          {failed > 0 && <span className="text-error">{failed} failed</span>}
          <span className="text-text-muted">{total} total</span>
        </div>
      )}

      {executionState !== "idle" && executionState !== "complete" && (
        <span className="text-accent capitalize">{executionState.replace("_", " ")}</span>
      )}

      <div className="ml-auto flex items-center gap-2">
        {isRunning ? (
          <button
            onClick={onStop}
            className="text-error hover:text-error/80 transition-colors"
            title="Stop"
          >
            &#9632; Stop
          </button>
        ) : (
          <button
            onClick={onRun}
            className="text-success hover:text-success/80 transition-colors"
            title="Run all tests"
          >
            &#9654; Run
          </button>
        )}
        <span className="text-text-muted">tauri-cypress v0.1.0</span>
      </div>
    </div>
  );
}
