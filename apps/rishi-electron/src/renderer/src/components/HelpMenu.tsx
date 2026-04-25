import { HelpCircle } from "lucide-react";

export function HelpMenu() {
  return (
    <button
      className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
      onClick={() => window.electron.openExternal("https://rishi.fidexa.org/help")}
      title="Help"
    >
      <HelpCircle size={18} />
    </button>
  );
}
