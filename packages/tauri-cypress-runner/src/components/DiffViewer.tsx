import { useState } from "react";
import type { DiffResult } from "../types";

interface DiffViewerProps {
  result: DiffResult;
  actualBase64: string;
  baselineBase64?: string;
  onUpdateBaseline: () => void;
  onDismiss: () => void;
}

type ViewTab = "side-by-side" | "diff" | "overlay";

export function DiffViewer({
  result,
  actualBase64,
  baselineBase64,
  onUpdateBaseline,
  onDismiss,
}: DiffViewerProps) {
  const [tab, setTab] = useState<ViewTab>("side-by-side");
  const [overlayOpacity, setOverlayOpacity] = useState(0.5);
  const matchPct = (result.match_percentage * 100).toFixed(2);

  return (
    <div className="absolute inset-0 z-50 bg-surface/95 flex flex-col">
      <div className="flex items-center justify-between px-3 py-2 border-b border-border">
        <div className="flex items-center gap-3">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">
            Screenshot Diff
          </span>
          <span
            className={`text-xs font-mono ${result.passed ? "text-success" : "text-error"}`}
          >
            {matchPct}% match
          </span>
          <span className="text-[9px] text-text-muted">
            ({result.diff_pixel_count} pixels differ)
          </span>
        </div>
        <div className="flex items-center gap-2">
          {!result.passed && (
            <button
              onClick={onUpdateBaseline}
              className="text-[10px] text-warning hover:text-warning/80 border border-warning/30 rounded px-2 py-0.5"
            >
              Update Baseline
            </button>
          )}
          <button
            onClick={onDismiss}
            className="text-text-muted hover:text-text text-xs"
          >
            &#10005; Close
          </button>
        </div>
      </div>

      <div className="flex items-center gap-2 px-3 py-1 border-b border-border">
        {(["side-by-side", "diff", "overlay"] as ViewTab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`text-[10px] px-2 py-0.5 rounded ${
              tab === t
                ? "bg-accent/20 text-accent"
                : "text-text-muted hover:text-text"
            }`}
          >
            {t.replace("-", " ")}
          </button>
        ))}
        {tab === "overlay" && (
          <input
            type="range"
            min="0"
            max="1"
            step="0.01"
            value={overlayOpacity}
            onChange={(e) => setOverlayOpacity(Number(e.target.value))}
            className="w-24 ml-2"
          />
        )}
      </div>

      <div className="flex-1 overflow-auto p-3">
        {tab === "side-by-side" && (
          <div className="grid grid-cols-2 gap-3 h-full">
            <div className="flex flex-col">
              <span className="text-[9px] uppercase text-text-muted tracking-wider mb-1">
                Baseline
              </span>
              {baselineBase64 ? (
                <img
                  src={baselineBase64}
                  alt="Baseline"
                  className="max-w-full object-contain rounded border border-border"
                />
              ) : (
                <div className="flex-1 flex items-center justify-center text-text-muted text-xs">
                  No baseline
                </div>
              )}
            </div>
            <div className="flex flex-col">
              <span className="text-[9px] uppercase text-text-muted tracking-wider mb-1">
                Actual
              </span>
              <img
                src={actualBase64}
                alt="Actual"
                className="max-w-full object-contain rounded border border-border"
              />
            </div>
          </div>
        )}

        {tab === "diff" && result.diff_path && (
          <div className="flex flex-col items-center">
            <span className="text-[9px] uppercase text-text-muted tracking-wider mb-1">
              Diff (red = changed)
            </span>
            <img
              src={`asset://localhost/${result.diff_path}`}
              alt="Diff"
              className="max-w-full object-contain rounded border border-border"
            />
          </div>
        )}

        {tab === "overlay" && baselineBase64 && (
          <div className="relative inline-block">
            <img
              src={baselineBase64}
              alt="Baseline"
              className="max-w-full object-contain rounded"
            />
            <img
              src={actualBase64}
              alt="Actual"
              className="absolute inset-0 max-w-full object-contain rounded"
              style={{ opacity: overlayOpacity }}
            />
          </div>
        )}
      </div>
    </div>
  );
}
