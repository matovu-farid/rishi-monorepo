import { useTestStore } from "../stores/testStore";
import type { TestRunnerResult } from "../types";

function StatusIcon({ result }: { result?: TestRunnerResult }) {
  if (!result) return <span className="w-3 h-3 rounded-full bg-text-muted inline-block" />;
  if (result.status === "passed") return <span className="text-success text-xs">&#10003;</span>;
  if (result.status === "failed") return <span className="text-error text-xs">&#10007;</span>;
  return <span className="text-warning text-xs">&#8722;</span>;
}

interface TestSidebarProps {
  onRunSingleTest: (filePath: string) => void;
}

export function TestSidebar({ onRunSingleTest }: TestSidebarProps) {
  const { files, results, selectedFile, selectFile } = useTestStore();

  if (files.length === 0) {
    return (
      <div className="p-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">Tests</div>
        <div className="text-text-muted text-xs">No test files loaded</div>
      </div>
    );
  }

  return (
    <div className="p-2">
      <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">
        Tests ({files.length})
      </div>
      <ul className="space-y-0.5">
        {files.map((file) => (
          <li key={file.path}>
            <button
              onClick={() => selectFile(file.path)}
              onDoubleClick={() => onRunSingleTest(file.path)}
              className={`w-full text-left flex items-center gap-1.5 px-1.5 py-1 rounded text-xs transition-colors ${
                selectedFile === file.path
                  ? "bg-accent/20 text-accent"
                  : "text-text hover:bg-white/5"
              }`}
              title="Click to select, double-click to run"
            >
              <StatusIcon result={results[file.path]} />
              <span className="truncate">{file.name}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
