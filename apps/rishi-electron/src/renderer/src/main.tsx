// Bootstrap order matters here. React DevTools installs a global hook
// (`__REACT_DEVTOOLS_GLOBAL_HOOK__`) that React looks for during its own
// initialization — once react-dom has loaded, that window has closed.
//
// All the React/router/Sentry initialization lives in `./bootstrap-app`,
// imported dynamically below so its static imports (react, react-dom, ...)
// are evaluated AFTER `connectToDevTools` has had a chance to install the
// hook. Without this ordering, the standalone DevTools window stays stuck
// on "Loading React Element Tree..." because it missed the initial mount.

async function bootstrap(): Promise<void> {
  if (import.meta.env.DEV) {
    try {
      // react-devtools-core ships no .d.ts of its own; suppress the
      // implicit-any rather than adding a stub file for this dev-only path.
      // @ts-expect-error untyped dev-only module
      const { connectToDevTools } = await import('react-devtools-core')
      connectToDevTools({ host: 'localhost', port: 8097 })
      // Tiny tick to ensure the hook is fully installed before react-dom
      // initialises in bootstrap-app. The hook installation is synchronous
      // but the connect WebSocket handshake is async — yielding here gives
      // it a frame to settle.
      await new Promise<void>((r) => setTimeout(r, 0))
    } catch (err) {
      console.warn('[devtools] react-devtools-core load failed', err)
    }
  }
  await import('./bootstrap-app')
}

void bootstrap()
