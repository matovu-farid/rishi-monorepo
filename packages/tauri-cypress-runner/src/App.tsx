import { PanelLayout } from "./components/PanelLayout";
import { TestSidebar } from "./components/TestSidebar";
import { AppPreview } from "./components/AppPreview";
import { CommandLog } from "./components/CommandLog";
import { IpcInspector } from "./components/IpcInspector";
import { StatusBar } from "./components/StatusBar";

export function App() {
  return (
    <div className="flex flex-col h-screen">
      <div className="h-9 bg-surface border-b border-border flex items-center px-3 gap-2">
        <span className="text-success">&#9654;</span>
        <span className="text-text text-sm font-medium">tauri-cypress</span>
      </div>
      <PanelLayout sidebar={<TestSidebar />} preview={<AppPreview />} inspector={<IpcInspector />} commandLog={<CommandLog />} />
      <StatusBar />
    </div>
  );
}
