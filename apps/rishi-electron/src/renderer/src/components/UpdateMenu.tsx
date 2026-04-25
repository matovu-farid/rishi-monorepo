import { useState, useEffect } from "react";
import { Download } from "lucide-react";

export function UpdateMenu() {
  const [updateAvailable, setUpdateAvailable] = useState(false);

  useEffect(() => {
    if (!window.electron) return;
    const unsub = window.electron.on("update-available", () => setUpdateAvailable(true));
    return unsub;
  }, []);

  if (!updateAvailable) return null;

  return (
    <button
      className="p-2 hover:bg-gray-100 rounded-lg transition-colors relative"
      onClick={() => window.electron.send("install-update")}
      title="Update available"
    >
      <Download size={18} />
      <span className="absolute top-1 right-1 w-2 h-2 bg-blue-600 rounded-full" />
    </button>
  );
}
