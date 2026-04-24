import { useState, useMemo, useCallback } from "react";
import { useTestStore } from "../stores/testStore";
import { useUiStore } from "../stores/uiStore";
import type { TestRunnerResult } from "../types";

function StatusIcon({ result }: { result?: TestRunnerResult }) {
  if (!result)
    return <span className="w-3 h-3 rounded-full bg-text-muted/40 inline-block shrink-0" />;
  if (result.status === "passed")
    return (
      <span className="text-success text-xs shrink-0 w-3 text-center">
        &#10003;
      </span>
    );
  if (result.status === "failed")
    return (
      <span className="text-error text-xs shrink-0 w-3 text-center">
        &#10007;
      </span>
    );
  return (
    <span className="text-warning text-xs shrink-0 w-3 text-center">
      &#8722;
    </span>
  );
}

function formatDuration(ms?: number): string {
  if (ms == null) return "";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function getErrorCount(result?: TestRunnerResult): number {
  if (!result) return 0;
  if (result.status !== "failed") return 0;
  const failedAssertions = result.assertions?.filter((a) => !a.passed).length ?? 0;
  return Math.max(failedAssertions, 1);
}

interface TestSidebarProps {
  onRunSingleTest: (filePath: string) => void;
}

export function TestSidebar({ onRunSingleTest }: TestSidebarProps) {
  const { files, results, selectedFile, selectFile, searchFilter, setSearchFilter } =
    useTestStore();
  const setSelectedFailedTest = useUiStore((s) => s.setSelectedFailedTest);
  const [hoveredFile, setHoveredFile] = useState<string | null>(null);

  const filteredFiles = useMemo(() => {
    if (!searchFilter.trim()) return files;
    const q = searchFilter.toLowerCase();
    return files.filter(
      (f) =>
        f.name.toLowerCase().includes(q) ||
        f.path.toLowerCase().includes(q)
    );
  }, [files, searchFilter]);

  const resultValues = Object.values(results);
  const passedCount = resultValues.filter((r) => r.status === "passed").length;
  const failedCount = resultValues.filter((r) => r.status === "failed").length;

  const handleFilterChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setSearchFilter(e.target.value);
    },
    [setSearchFilter]
  );

  const handleFileClick = useCallback(
    (filePath: string) => {
      selectFile(filePath);
      const result = results[filePath];
      if (result?.status === "failed") {
        setSelectedFailedTest(filePath);
      } else {
        setSelectedFailedTest(null);
      }
    },
    [selectFile, results, setSelectedFailedTest]
  );

  if (files.length === 0) {
    return (
      <div className="p-2 h-full flex flex-col">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">
          Tests
        </div>
        <div className="text-text-muted text-xs flex-1 flex items-center justify-center">
          No test files loaded
        </div>
      </div>
    );
  }

  return (
    <div className="p-2 h-full flex flex-col">
      {/* Header with stats */}
      <div className="flex items-center justify-between mb-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider">
          Tests ({files.length})
        </div>
        {resultValues.length > 0 && (
          <div className="flex items-center gap-1.5 text-[9px]">
            {passedCount > 0 && (
              <span className="text-success">{passedCount}</span>
            )}
            {failedCount > 0 && (
              <span className="text-error">{failedCount}</span>
            )}
          </div>
        )}
      </div>

      {/* Search/filter input */}
      <div className="mb-2">
        <input
          type="text"
          value={searchFilter}
          onChange={handleFilterChange}
          placeholder="Filter tests..."
          className="w-full text-[10px] bg-surface border border-border rounded px-2 py-1 text-text outline-none focus:border-accent placeholder:text-text-muted/50"
        />
      </div>

      {/* Test file list */}
      <ul className="space-y-0.5 flex-1 overflow-auto">
        {filteredFiles.map((file) => {
          const result = results[file.path];
          const errorCount = getErrorCount(result);
          const isHovered = hoveredFile === file.path;
          const isSelected = selectedFile === file.path;

          // Color coding based on status
          let textColorClass = "text-text";
          if (result?.status === "passed") textColorClass = "text-success";
          else if (result?.status === "failed") textColorClass = "text-error";
          else if (!result) textColorClass = "text-text-muted";

          return (
            <li
              key={file.path}
              onMouseEnter={() => setHoveredFile(file.path)}
              onMouseLeave={() => setHoveredFile(null)}
            >
              <button
                onClick={() => handleFileClick(file.path)}
                className={`w-full text-left flex items-center gap-1.5 px-1.5 py-1.5 rounded text-xs transition-colors group ${
                  isSelected
                    ? "bg-accent/20 text-accent"
                    : "hover:bg-white/5"
                }`}
                title="Click to select, double-click to run"
              >
                <StatusIcon result={result} />
                <span
                  className={`truncate flex-1 ${
                    isSelected ? "text-accent" : textColorClass
                  }`}
                >
                  {file.name}
                </span>

                {/* Duration badge */}
                {result?.duration_ms != null && (
                  <span className="text-text-muted text-[9px] shrink-0 tabular-nums">
                    {formatDuration(result.duration_ms)}
                  </span>
                )}

                {/* Error count badge */}
                {errorCount > 0 && (
                  <span className="bg-error/20 text-error text-[9px] rounded-full px-1.5 py-0 min-w-[16px] text-center shrink-0">
                    {errorCount}
                  </span>
                )}

                {/* Play button on hover */}
                {isHovered && (
                  <span
                    onClick={(e) => {
                      e.stopPropagation();
                      onRunSingleTest(file.path);
                    }}
                    className="text-success hover:text-success/80 text-[11px] shrink-0 cursor-pointer ml-0.5"
                    title="Run this test"
                  >
                    &#9654;
                  </span>
                )}
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
