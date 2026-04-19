import { useRef, useEffect } from "react";
import type { BuildOutput as BuildOutputLine } from "../types";

interface BuildOutputProps {
  lines: BuildOutputLine[];
  visible: boolean;
  onDismiss: () => void;
  buildFailed: boolean;
}

export function BuildOutput({ lines, visible, onDismiss, buildFailed }: BuildOutputProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [lines.length]);

  if (!visible) return null;

  return (
    <div className="absolute inset-0 z-50 bg-surface/95 flex flex-col">
      <div className="flex items-center justify-between px-3 py-2 border-b border-border">
        <div className="flex items-center gap-2">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">Build Output</span>
          {buildFailed && <span className="text-error text-xs">Build Failed</span>}
          {!buildFailed && lines.length > 0 && <span className="text-accent text-xs animate-pulse">Building...</span>}
        </div>
        <button
          onClick={onDismiss}
          className="text-text-muted hover:text-text text-xs"
        >
          &#10005; Close
        </button>
      </div>
      <div ref={scrollRef} className="flex-1 overflow-auto p-3 font-mono text-[11px]">
        {lines.map((line, i) => (
          <div
            key={i}
            className={line.stream === "stderr" ? "text-error" : "text-text"}
          >
            {line.line}
          </div>
        ))}
        {lines.length === 0 && (
          <div className="text-text-muted">Waiting for build output...</div>
        )}
      </div>
    </div>
  );
}
