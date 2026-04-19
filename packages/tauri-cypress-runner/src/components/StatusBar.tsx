export function StatusBar() {
  return (<div className="h-6 bg-panel-bg border-t border-border flex items-center px-3 text-[11px] gap-4"><div className="flex items-center gap-1.5"><div className="w-2 h-2 rounded-full bg-text-muted" /><span className="text-text-muted">Disconnected</span></div><div className="text-text-muted ml-auto">tauri-cypress v0.1.0</div></div>);
}
