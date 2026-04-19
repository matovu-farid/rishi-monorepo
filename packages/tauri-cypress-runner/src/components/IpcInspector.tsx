import { useState, useCallback } from "react";
import { useIpcStore } from "../stores/ipcStore";

function JsonExpander({ label, data }: { label: string; data: unknown }) {
  const [open, setOpen] = useState(false);
  const json = JSON.stringify(data, null, 2);
  const isLong = json.length > 40;

  if (!isLong) return <span className="text-text-muted">{json}</span>;

  return (
    <span>
      <button onClick={() => setOpen(!open)} className="text-accent hover:underline">
        {open ? "collapse" : label}
      </button>
      {open && (
        <pre className="mt-0.5 text-[10px] text-text-muted bg-surface rounded p-1 overflow-x-auto max-h-32">
          {json}
        </pre>
      )}
    </span>
  );
}

export function IpcInspector() {
  const entries = useIpcStore((s) => s.entries);
  const [filter, setFilter] = useState("");

  const filtered = filter
    ? entries.filter((e) => e.command.toLowerCase().includes(filter.toLowerCase()))
    : entries;

  const onFilterChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    setFilter(e.target.value);
  }, []);

  if (entries.length === 0) {
    return (
      <div className="p-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">IPC Inspector</div>
        <div className="text-text-muted text-xs">No IPC traffic</div>
      </div>
    );
  }

  return (
    <div className="p-2 flex flex-col h-full">
      <div className="flex items-center gap-2 mb-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider">
          IPC Inspector ({filtered.length})
        </div>
        <input
          type="text"
          value={filter}
          onChange={onFilterChange}
          placeholder="Filter command..."
          className="ml-auto text-[10px] bg-panel-bg border border-border rounded px-1.5 py-0.5 text-text outline-none focus:border-accent w-32"
        />
      </div>
      <div className="flex-1 overflow-auto">
        <table className="w-full text-[11px]">
          <thead>
            <tr className="text-text-muted text-left border-b border-border">
              <th className="py-1 pr-2 font-normal">Command</th>
              <th className="py-1 pr-2 font-normal">Args</th>
              <th className="py-1 pr-2 font-normal">Response</th>
              <th className="py-1 pr-2 font-normal w-12">Mock</th>
              <th className="py-1 font-normal w-14 text-right">Time</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((entry, i) => (
              <tr key={i} className="border-b border-border/50 hover:bg-white/5">
                <td className="py-1 pr-2 font-mono text-accent">{entry.command}</td>
                <td className="py-1 pr-2"><JsonExpander label="args" data={entry.args} /></td>
                <td className="py-1 pr-2"><JsonExpander label="resp" data={entry.response} /></td>
                <td className="py-1 pr-2">
                  {entry.mocked ? (
                    <span className="bg-warning/20 text-warning rounded px-1 py-0.5 text-[9px]">mock</span>
                  ) : (
                    <span className="text-text-muted text-[9px]">real</span>
                  )}
                </td>
                <td className="py-1 text-right text-text-muted">{entry.duration_ms}ms</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
