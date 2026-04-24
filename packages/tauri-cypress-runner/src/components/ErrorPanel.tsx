import { useTestStore } from "../stores/testStore";
import { useUiStore } from "../stores/uiStore";

export function ErrorPanel() {
  const selectedFailedTest = useUiStore((s) => s.selectedFailedTest);
  const setSelectedFailedTest = useUiStore((s) => s.setSelectedFailedTest);
  const results = useTestStore((s) => s.results);
  const testResults = useTestStore((s) => s.testResults);

  // Find the result in both file-level and test-level results
  const result = selectedFailedTest
    ? results[selectedFailedTest] ?? testResults[selectedFailedTest]
    : null;

  if (!result || result.status !== "failed") return null;

  const failedAssertions = result.assertions?.filter((a) => !a.passed) ?? [];
  const hasAssertions = failedAssertions.length > 0;

  return (
    <div className="absolute bottom-7 left-0 right-0 z-40 max-h-[40vh] flex flex-col bg-surface border-t-2 border-error/60">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-2 bg-error/10 border-b border-error/20 shrink-0">
        <div className="flex items-center gap-2">
          <span className="text-error text-sm">&#10007;</span>
          <span className="text-error text-xs font-medium">
            Test Failed
          </span>
          <span className="text-text-muted text-[10px] truncate max-w-md">
            {selectedFailedTest}
          </span>
        </div>
        <button
          onClick={() => setSelectedFailedTest(null)}
          className="text-text-muted hover:text-text text-xs px-1.5"
        >
          &#10005; Close
        </button>
      </div>

      {/* Error content */}
      <div className="flex-1 overflow-auto p-4 space-y-3">
        {/* Error message */}
        {result.error && (
          <div className="rounded border border-error/30 bg-error/5 p-3">
            <div className="text-[9px] uppercase text-error/60 tracking-wider mb-1.5">
              Error
            </div>
            <pre className="text-error text-xs font-mono whitespace-pre-wrap break-all leading-relaxed">
              {result.error}
            </pre>
          </div>
        )}

        {/* Assertion failures */}
        {hasAssertions && (
          <div className="rounded border border-error/20 bg-panel-bg p-3">
            <div className="text-[9px] uppercase text-error/60 tracking-wider mb-2">
              Failed Assertions ({failedAssertions.length})
            </div>
            <div className="space-y-2">
              {failedAssertions.map((assertion, i) => (
                <div
                  key={i}
                  className="border border-border/50 rounded p-2 bg-surface"
                >
                  <div className="flex items-start gap-1.5 mb-1.5">
                    <span className="text-error text-[10px] shrink-0 mt-0.5">
                      &#10007;
                    </span>
                    <span className="text-text text-xs">
                      {assertion.description}
                    </span>
                  </div>
                  <div className="grid grid-cols-2 gap-2 ml-4">
                    <div>
                      <div className="text-[9px] text-text-muted mb-0.5">
                        Expected
                      </div>
                      <pre className="text-success text-[10px] font-mono bg-success/5 rounded px-2 py-1 overflow-x-auto">
                        {JSON.stringify(assertion.expected, null, 2)}
                      </pre>
                    </div>
                    <div>
                      <div className="text-[9px] text-text-muted mb-0.5">
                        Actual
                      </div>
                      <pre className="text-error text-[10px] font-mono bg-error/5 rounded px-2 py-1 overflow-x-auto">
                        {JSON.stringify(assertion.actual, null, 2)}
                      </pre>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* All assertions summary */}
        {result.assertions && result.assertions.length > 0 && (
          <div className="text-[10px] text-text-muted">
            {result.assertions.filter((a) => a.passed).length} passed,{" "}
            {failedAssertions.length} failed of {result.assertions.length} total
            assertions
          </div>
        )}

        {/* Duration */}
        {result.duration_ms != null && (
          <div className="text-[10px] text-text-muted">
            Duration: {result.duration_ms}ms
          </div>
        )}
      </div>
    </div>
  );
}
