// Bootstrap order matters here. React DevTools installs a global hook
// (`__REACT_DEVTOOLS_GLOBAL_HOOK__`) that React looks for *during its own
// initialization* — once `react-dom` is loaded the window has closed.
//
// All the React/router/Sentry initialization lives in `./bootstrap-app`,
// imported dynamically below so its static imports (react, react-dom, ...)
// are evaluated AFTER `connectToDevTools` has had a chance to install the
// hook. Without this two-step, the standalone DevTools window stays stuck
// on "Loading React Element Tree..." because it missed the initial mount.

async function bootstrap(): Promise<void> {
  if (import.meta.env.DEV) {
    try {
      // react-devtools-core ships no .d.ts of its own; suppress the
      // implicit-any rather than adding a stub file for this dev-only path.
      // @ts-expect-error untyped dev-only module
      const { connectToDevTools } = await import('react-devtools-core')
      connectToDevTools({ host: 'localhost', port: 8097 })
    } catch (err) {
      console.warn('[devtools] react-devtools-core load failed', err)
    }
  }
  await import('./bootstrap-app')
}

void bootstrap()
