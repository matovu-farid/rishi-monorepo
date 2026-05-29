// Dev-only append-only debug log.
//
// Why a separate path from errorDump.ts: `dumpError` does a
// read-merge-write per call, which under burst load (hundreds of
// `relocated` + state-mirror writes within a few hundred milliseconds)
// drops entries because read/write windows overlap across concurrent
// invocations. `debugLog` writes NDJSON via `fs.appendFile` so each
// renderer call is atomic at the OS level — no data loss.
//
// Output: `<userData>/debug-log.ndjson`. One JSON object per line. Read
// it with `jq -s . debug-log.ndjson` or process line-by-line.
//
// Convention: keep `source` short and hierarchical so grep stays useful
// (e.g. `view:relocated`, `nav:state`, `mirror:paragraphs`). `data` is
// any JSON-serialisable value; non-serialisable fields are dropped.

const IS_DEV = import.meta.env.DEV

// `window.electron` is not present in vitest / SSR / very-early renderer
// boot. Bail safely so the renderer itself never crashes from a logging
// call site — debugLog is strictly a diagnostic tool, never a load-bearing
// path. Resolved at call time so tests can stub `window.electron` later.
function getAppender(): ((line: string) => Promise<void>) | null {
  if (typeof window === 'undefined') return null
  const e = (window as unknown as { electron?: { appendDebugLog?: (line: string) => Promise<void> } }).electron
  return e?.appendDebugLog ?? null
}

export function debugLog(source: string, data: Record<string, unknown> = {}): void {
  if (!IS_DEV) return
  const append = getAppender()
  if (!append) return
  try {
    const line = JSON.stringify({
      t: new Date().toISOString(),
      source,
      ...data
    })
    void append(line).catch(() => {
      // Last resort: console — if IPC itself failed, no point throwing.
      console.warn('[debug-log] append failed', source, data)
    })
  } catch (err) {
    // JSON.stringify can throw on circular refs / BigInt. Fall back to a
    // line that at least preserves the source so the timeline is intact.
    void append(
      JSON.stringify({
        t: new Date().toISOString(),
        source,
        stringifyError: String(err)
      })
    ).catch(() => {})
  }
}
