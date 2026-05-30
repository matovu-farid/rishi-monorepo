import './styles/globals.css'
import './testing/expose-stores'
import { StrictMode } from 'react'
import ReactDOM from 'react-dom/client'
import { RouterProvider, createRouter, createHashHistory } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'
import Providers from './components/providers'
import { initSentry } from './utils/sentry'

// React DevTools (standalone) — connect to the GUI running on
// ws://localhost:8097. The Chrome-extension flavour of React DevTools
// doesn't fully work in modern Electron (chrome.storage / Manifest V3
// gaps), so we use the standalone app: run `pnpm exec react-devtools`
// in a separate terminal and the Components / Profiler tabs show up
// there. Wrapped in import.meta.env.DEV so the connect call never ships
// to production.
if (import.meta.env.DEV) {
  // react-devtools-core ships no .d.ts of its own; suppress the implicit-any
  // for this dev-only side-effect rather than adding a stub file.
  // @ts-expect-error untyped dev-only module
  void import('react-devtools-core').then(({ connectToDevTools }) => {
    connectToDevTools({ host: 'localhost', port: 8097 })
  })
}

initSentry()

// Use hash history so routing works in Electron
const router = createRouter({ routeTree, history: createHashHistory() })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}

const rootElement = document.getElementById('root')
if (!rootElement) {
  throw new Error('Renderer bootstrap failed: #root element not found in document')
}
if (!rootElement.innerHTML) {
  const root = ReactDOM.createRoot(rootElement)
  root.render(
    <StrictMode>
      <Providers>
        <RouterProvider router={router} />
      </Providers>
    </StrictMode>
  )
}
