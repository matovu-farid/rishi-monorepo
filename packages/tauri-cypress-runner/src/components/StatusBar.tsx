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

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  const minutes = Math.floor(ms / 60000);
  const seconds = ((ms % 60000) / 1000).toFixed(0);
  return `${minutes}m ${seconds}s`;
}

export function StatusBar({
  connectionState,
  executionState,
  onRun,
  onStop,
}: StatusBarProps) {
  const { files, results, currentlyRunningTest, totalDuration } =
    useTestStore();
  const resultValues = Object.values(results);
  const passed = resultValues.filter((r) => r.status === "passed").length;
  const failed = resultValues.filter((r) => r.status === "failed").length;
  const total = files.length;
  const completed = resultValues.length;
  const isRunning =
    executionState === "building" ||
    executionState === "launching" ||
    executionState === "connecting" ||
    executionState === "running";
  const progressPercent = total > 0 ? (completed / total) * 100 : 0;

  return (
    <div className="bg-panel-bg border-t border-border shrink-0">
      {/* Progress bar - only visible when running */}
      {isRunning && total > 0 && (
        <div className="h-0.5 bg-border w-full">
          <div
            className="h-full bg-accent transition-all duration-300 ease-out"
            style={{ width: `${progressPercent}%` }}
          />
        </div>
      )}

      <div className="h-6 flex items-center px-3 text-[11px] gap-4">
        {/* Connection status */}
        <div className="flex items-center gap-1.5">
          <div
            className={`w-2 h-2 rounded-full ${CONNECTION_COLORS[connectionState]}`}
          />
          <span className="text-text-muted">
            {CONNECTION_LABELS[connectionState]}
          </span>
        </div>

        {/* Test counts */}
        {total > 0 && (
          <div className="flex items-center gap-2">
            {passed > 0 && (
              <span className="text-success">{passed} passed</span>
            )}
            {failed > 0 && (
              <span className="text-error">{failed} failed</span>
            )}
            <span className="text-text-muted">
              {completed}/{total}
            </span>
          </div>
        )}

        {/* Currently running test name */}
        {isRunning && currentlyRunningTest && (
          <div className="flex items-center gap-1.5 min-w-0 flex-1">
            <span className="text-accent animate-pulse text-[10px]">
              &#9679;
            </span>
            <span className="text-text-muted truncate text-[10px]">
              {currentlyRunningTest}
            </span>
          </div>
        )}

        {/* Execution state when not showing running test */}
        {isRunning && !currentlyRunningTest && executionState !== "running" && (
          <span className="text-accent capitalize text-[10px]">
            {executionState.replace("_", " ")}...
          </span>
        )}

        {/* Total duration after completion */}
        {executionState === "complete" && totalDuration != null && (
          <span className="text-text-muted text-[10px]">
            Done in {formatDuration(totalDuration)}
          </span>
        )}

        {/* Right side controls */}
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
          <span className="text-text-muted/50">tauri-cypress v0.1.0</span>
        </div>
      </div>
    </div>
  );
}
