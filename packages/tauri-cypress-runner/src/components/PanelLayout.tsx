import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import type { ReactNode } from "react";

function Handle({ dir = "vertical" }: { dir?: "vertical" | "horizontal" }) {
  return <PanelResizeHandle className={`${dir === "vertical" ? "w-1" : "h-1"} bg-border hover:bg-accent transition-colors`} />;
}

export function PanelLayout({ sidebar, preview, inspector, commandLog }: { sidebar: ReactNode; preview: ReactNode; inspector: ReactNode; commandLog: ReactNode }) {
  return (
    <PanelGroup direction="horizontal" className="flex-1">
      <Panel defaultSize={18} minSize={12} maxSize={30}>
        <div className="h-full bg-panel-bg overflow-auto">{sidebar}</div>
      </Panel>
      <Handle />
      <Panel defaultSize={54} minSize={30}>
        <PanelGroup direction="vertical">
          <Panel defaultSize={55} minSize={20}>
            <div className="h-full bg-surface overflow-auto">{preview}</div>
          </Panel>
          <Handle dir="horizontal" />
          <Panel defaultSize={45} minSize={15}>
            <div className="h-full bg-surface overflow-auto">{inspector}</div>
          </Panel>
        </PanelGroup>
      </Panel>
      <Handle />
      <Panel defaultSize={28} minSize={15} maxSize={40}>
        <div className="h-full bg-panel-bg overflow-auto">{commandLog}</div>
      </Panel>
    </PanelGroup>
  );
}
