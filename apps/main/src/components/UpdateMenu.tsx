import { useEffect, useState } from "react";
import { Settings } from "lucide-react";
import { getVersion } from "@tauri-apps/api/app";
import {
  Popover,
  PopoverTrigger,
  PopoverContent,
} from "@components/components/ui/popover";
import {
  checkForUpdates,
  renderStatus,
  useUpdateStore,
} from "@/modules/updater";

export function UpdateMenu() {
  const status = useUpdateStore((s) => s.status);
  const [version, setVersion] = useState<string>("");

  useEffect(() => {
    getVersion()
      .then(setVersion)
      .catch(() => {
        // getVersion only fails outside a Tauri context; safe to ignore.
      });
  }, []);

  const busy =
    status.kind === "checking" ||
    status.kind === "downloading" ||
    status.kind === "installing";
  const statusLine = renderStatus(status);

  return (
    <Popover>
      <PopoverTrigger
        aria-label="App settings"
        className="p-2 rounded-md hover:bg-black/10 text-black"
      >
        <Settings size={20} />
      </PopoverTrigger>
      <PopoverContent align="end" className="w-64">
        <div className="text-sm text-muted-foreground mb-3">
          Rishi {version ? `v${version}` : ""}
        </div>
        <button
          type="button"
          disabled={busy}
          onClick={() => void checkForUpdates({ silent: false })}
          className="w-full rounded-md border px-3 py-1.5 text-sm hover:bg-black/5 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {busy ? "Checking\u2026" : "Check for Updates"}
        </button>
        {statusLine && (
          <div className="mt-2 text-xs text-muted-foreground">{statusLine}</div>
        )}
      </PopoverContent>
    </Popover>
  );
}
