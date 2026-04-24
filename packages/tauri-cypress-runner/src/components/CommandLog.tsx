import { useState, useEffect, useRef, useMemo, useCallback } from "react";
import { useCommandStore } from "../stores/commandStore";
import type { GroupedCommandEntry } from "../stores/commandStore";
import type { CommandEntry } from "../types";

function formatDuration(ms?: number): string {
  if (ms == null) return "";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

/** Derives the overall group status from its entries */
function getGroupStatus(
  entries: GroupedCommandEntry[]
): "passed" | "failed" | "running" | "pending" {
  if (entries.some((e) => e.status === "failed")) return "failed";
  if (entries.some((e) => e.status === "running")) return "running";
  if (entries.every((e) => e.status === "passed")) return "passed";
  return "pending";
}

/** Derives total duration for a group */
function getGroupDuration(entries: GroupedCommandEntry[]): number | undefined {
  // Use the result entry's duration if one exists
  const resultEntry = entries.find((e) => e.name.startsWith("result: "));
  if (resultEntry?.duration != null) return resultEntry.duration;

  // Sum all durations
  const durations = entries
    .filter((e) => e.duration != null)
    .map((e) => e.duration!);
  if (durations.length === 0) return undefined;
  return durations.reduce((a, b) => a + b, 0);
}

interface TestGroup {
  name: string;
  entries: { entry: GroupedCommandEntry; globalIndex: number }[];
  status: "passed" | "failed" | "running" | "pending";
  duration?: number;
}

interface CommandLogProps {
  onActivateTimeTravel: (snapshotIndex: number) => void;
  onSnapshotHover: (snapshotIndex: number | null) => void;
}

export function CommandLog({
  onActivateTimeTravel,
  onSnapshotHover,
}: CommandLogProps) {
  const { entries, selectedIndex, selectEntry, setHoveredIndex } =
    useCommandStore();
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(
    new Set()
  );
  const scrollRef = useRef<HTMLDivElement>(null);
  const lastEntryCountRef = useRef(0);

  // Group commands by test name
  const { groups, ungrouped } = useMemo(() => {
    const groupMap = new Map<string, TestGroup>();
    const ungroupedEntries: { entry: GroupedCommandEntry; globalIndex: number }[] = [];

    entries.forEach((entry, index) => {
      const testName = entry.testName;
      if (testName) {
        if (!groupMap.has(testName)) {
          groupMap.set(testName, {
            name: testName,
            entries: [],
            status: "pending",
            duration: undefined,
          });
        }
        groupMap.get(testName)!.entries.push({ entry, globalIndex: index });
      } else {
        ungroupedEntries.push({ entry, globalIndex: index });
      }
    });

    // Compute group statuses
    for (const group of groupMap.values()) {
      group.status = getGroupStatus(group.entries.map((e) => e.entry));
      group.duration = getGroupDuration(group.entries.map((e) => e.entry));
    }

    return { groups: Array.from(groupMap.values()), ungrouped: ungroupedEntries };
  }, [entries]);

  // Auto-scroll to bottom when new entries arrive
  useEffect(() => {
    if (entries.length > lastEntryCountRef.current && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
    lastEntryCountRef.current = entries.length;
  }, [entries.length]);

  const toggleGroup = useCallback((name: string) => {
    setCollapsedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(name)) {
        next.delete(name);
      } else {
        next.add(name);
      }
      return next;
    });
  }, []);

  const handleEntryClick = useCallback(
    (index: number, entry: GroupedCommandEntry) => {
      selectEntry(index);
      if (entry.snapshotIndex >= 0) {
        onActivateTimeTravel(entry.snapshotIndex);
      }
    },
    [selectEntry, onActivateTimeTravel]
  );

  const handleEntryHover = useCallback(
    (index: number | null, entry?: GroupedCommandEntry) => {
      setHoveredIndex(index);
      if (index != null && entry && entry.snapshotIndex >= 0) {
        onSnapshotHover(entry.snapshotIndex);
      } else {
        onSnapshotHover(null);
      }
    },
    [setHoveredIndex, onSnapshotHover]
  );

  if (entries.length === 0) {
    return (
      <div className="p-2 h-full flex flex-col">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">
          Command Log
        </div>
        <div className="text-text-muted text-xs flex-1 flex items-center justify-center">
          Run a test to see commands
        </div>
      </div>
    );
  }

  return (
    <div className="p-2 h-full flex flex-col">
      <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2 flex items-center justify-between">
        <span>Command Log ({entries.length})</span>
        {groups.length > 0 && (
          <span className="text-text-muted">
            {groups.length} test{groups.length !== 1 ? "s" : ""}
          </span>
        )}
      </div>

      <div ref={scrollRef} className="flex-1 overflow-auto space-y-1">
        {/* Ungrouped commands */}
        {ungrouped.map(({ entry, globalIndex }) => (
          <CommandEntryRow
            key={globalIndex}
            entry={entry}
            globalIndex={globalIndex}
            isSelected={selectedIndex === globalIndex}
            onClick={handleEntryClick}
            onHover={handleEntryHover}
          />
        ))}

        {/* Grouped test sections */}
        {groups.map((group) => {
          const isCollapsed = collapsedGroups.has(group.name);
          return (
            <div
              key={group.name}
              className="border border-border/50 rounded overflow-hidden"
            >
              {/* Group header */}
              <button
                onClick={() => toggleGroup(group.name)}
                className="w-full flex items-center gap-1.5 px-2 py-1.5 bg-surface hover:bg-white/5 text-xs transition-colors"
              >
                <span className="text-text-muted text-[9px] shrink-0">
                  {isCollapsed ? "\u25B6" : "\u25BC"}
                </span>
                <GroupStatusIcon status={group.status} />
                <span
                  className={`truncate flex-1 text-left font-medium ${
                    group.status === "passed"
                      ? "text-success"
                      : group.status === "failed"
                        ? "text-error"
                        : "text-text"
                  }`}
                >
                  {group.name}
                </span>
                {group.duration != null && (
                  <span className="text-text-muted text-[9px] shrink-0 tabular-nums">
                    {formatDuration(group.duration)}
                  </span>
                )}
                <span className="text-text-muted text-[9px] shrink-0">
                  ({group.entries.length})
                </span>
              </button>

              {/* Group entries */}
              {!isCollapsed && (
                <div className="border-t border-border/30">
                  {group.entries.map(({ entry, globalIndex }) => (
                    <div key={globalIndex}>
                      <CommandEntryRow
                        entry={entry}
                        globalIndex={globalIndex}
                        isSelected={selectedIndex === globalIndex}
                        onClick={handleEntryClick}
                        onHover={handleEntryHover}
                        nested
                      />

                      {/* Show assertions inline for result entries */}
                      {entry.name.startsWith("result: ") &&
                        entry.assertions &&
                        entry.assertions.length > 0 && (
                          <div className="ml-6 border-l-2 border-border/30 pl-2 pb-1">
                            {entry.assertions.map((assertion, ai) => (
                              <div
                                key={ai}
                                className="flex items-start gap-1.5 py-0.5 text-[10px]"
                              >
                                <span
                                  className={`shrink-0 ${
                                    assertion.passed
                                      ? "text-success"
                                      : "text-error"
                                  }`}
                                >
                                  {assertion.passed ? "\u2713" : "\u2717"}
                                </span>
                                <span
                                  className={`flex-1 ${
                                    assertion.passed
                                      ? "text-text-muted"
                                      : "text-error"
                                  }`}
                                >
                                  {assertion.description}
                                </span>
                                {!assertion.passed && (
                                  <div className="text-[9px] text-error/70">
                                    <span className="text-text-muted">
                                      expected:{" "}
                                    </span>
                                    <span className="font-mono">
                                      {JSON.stringify(assertion.expected)}
                                    </span>
                                    <span className="text-text-muted">
                                      {" "}
                                      actual:{" "}
                                    </span>
                                    <span className="font-mono">
                                      {JSON.stringify(assertion.actual)}
                                    </span>
                                  </div>
                                )}
                              </div>
                            ))}
                          </div>
                        )}

                      {/* Inline error details for failed entries */}
                      {entry.error && (
                        <div className="ml-6 mr-2 mb-1 text-[10px] text-error bg-error/10 border border-error/20 rounded px-2 py-1.5 font-mono break-all whitespace-pre-wrap">
                          {entry.error}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function GroupStatusIcon({
  status,
}: {
  status: "passed" | "failed" | "running" | "pending";
}) {
  switch (status) {
    case "passed":
      return (
        <span className="w-4 h-4 rounded-full bg-success/20 text-success text-[10px] flex items-center justify-center shrink-0">
          &#10003;
        </span>
      );
    case "failed":
      return (
        <span className="w-4 h-4 rounded-full bg-error/20 text-error text-[10px] flex items-center justify-center shrink-0">
          &#10007;
        </span>
      );
    case "running":
      return (
        <span className="w-4 h-4 rounded-full bg-accent/20 text-accent text-[10px] flex items-center justify-center shrink-0 animate-pulse">
          &#9679;
        </span>
      );
    default:
      return (
        <span className="w-4 h-4 rounded-full bg-text-muted/20 text-text-muted text-[10px] flex items-center justify-center shrink-0">
          &#9679;
        </span>
      );
  }
}

interface CommandEntryRowProps {
  entry: GroupedCommandEntry;
  globalIndex: number;
  isSelected: boolean;
  onClick: (index: number, entry: GroupedCommandEntry) => void;
  onHover: (index: number | null, entry?: GroupedCommandEntry) => void;
  nested?: boolean;
}

function CommandEntryRow({
  entry,
  globalIndex,
  isSelected,
  onClick,
  onHover,
  nested,
}: CommandEntryRowProps) {
  return (
    <button
      onClick={() => onClick(globalIndex, entry)}
      onMouseEnter={() => onHover(globalIndex, entry)}
      onMouseLeave={() => onHover(null)}
      className={`w-full text-left flex items-center gap-1.5 px-1.5 py-1 text-xs transition-colors ${
        nested ? "pl-4" : ""
      } ${
        isSelected
          ? "bg-accent/20 text-accent"
          : "text-text hover:bg-white/5"
      }`}
    >
      <CmdStatusIcon status={entry.status} />
      <span className="truncate flex-1 font-mono">{entry.name}</span>
      {entry.snapshotIndex >= 0 && (
        <span
          className="text-text-muted text-[9px] shrink-0"
          title="Has snapshot"
        >
          &#128247;
        </span>
      )}
      {entry.duration != null && (
        <span className="text-text-muted text-[10px] shrink-0 tabular-nums">
          {formatDuration(entry.duration)}
        </span>
      )}
    </button>
  );
}

function CmdStatusIcon({ status }: { status: CommandEntry["status"] }) {
  switch (status) {
    case "passed":
      return <span className="text-success text-[10px]">&#10003;</span>;
    case "failed":
      return <span className="text-error text-[10px]">&#10007;</span>;
    case "running":
      return (
        <span className="text-accent text-[10px] animate-pulse">&#9679;</span>
      );
    default:
      return <span className="text-text-muted text-[10px]">&#9679;</span>;
  }
}
