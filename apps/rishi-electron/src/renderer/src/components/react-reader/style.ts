import type { CSSProperties } from 'react'

export interface IReactReaderStyle {
  container: CSSProperties
  readerArea: CSSProperties
  containerExpanded: CSSProperties
  titleArea: CSSProperties
  reader: CSSProperties
  swipeWrapper: CSSProperties
  prev: CSSProperties
  next: CSSProperties
  arrow: CSSProperties
  arrowHover: CSSProperties
  tocBackground: CSSProperties
  toc: CSSProperties
  tocArea: CSSProperties
  tocAreaButton: CSSProperties
  tocButton: CSSProperties
  tocButtonExpanded: CSSProperties
  tocButtonBar: CSSProperties
  tocButtonBarTop: CSSProperties
  loadingView: CSSProperties
  errorView: CSSProperties
  tocButtonBottom: CSSProperties
}

export const ReactReaderStyle: IReactReaderStyle = {
  container: {
    overflow: 'hidden',
    position: 'relative',
    height: '100%'
  },
  readerArea: {
    position: 'relative',
    zIndex: 1,
    height: '100%',
    width: '100%',
    // Default to app background so the bare reader (no reader-theme override)
    // tracks dark mode. Per-theme overrides in `createIReactReaderTheme` win.
    backgroundColor: 'var(--background)',
    // `prefers-reduced-motion` users get an instant swap instead of a
    // 300ms cross-fade.
    transition: 'background-color .3s ease',
    transitionDuration: 'var(--motion-duration, .3s)'
  },
  containerExpanded: {
    transform: 'translateX(256px)'
  },
  titleArea: {
    position: 'absolute',
    top: 14,
    left: 120,
    right: 220,
    textAlign: 'center',
    color: 'var(--muted-foreground)',
    fontSize: 14,
    fontWeight: 500,
    whiteSpace: 'nowrap' as const,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    userSelect: 'none',
    zIndex: 1
  },
  reader: {
    position: 'absolute',
    top: 50,
    left: 50,
    bottom: 30,
    right: 50
  },
  swipeWrapper: {
    position: 'absolute',
    top: 0,
    left: 0,
    bottom: 0,
    right: 0,
    zIndex: 200
  },
  prev: {
    left: 1
  },
  next: {
    right: 1
  },
  arrow: {
    // No `outline: 'none'` here — keyboard focus ring is added on the
    // consuming `TocToggleButton` / `NavigationArrows` components via
    // `:focus-visible` styles so a11y contract (WCAG 2.4.7) is preserved.
    border: 'none',
    background: 'none',
    position: 'fixed',
    top: '48%',
    marginTop: -32,
    fontSize: 64,
    padding: '0 40px',
    // `--muted-foreground` adapts to the active theme; reader-theme wrappers
    // (createIReactReaderTheme) still override with theme.arrowColor.
    color: 'var(--muted-foreground)',
    fontFamily: 'arial, sans-serif',
    cursor: 'pointer',
    userSelect: 'none',
    appearance: 'none',
    fontWeight: 'normal'
  },
  arrowHover: {
    color: 'var(--foreground)'
  },
  toc: {},
  tocBackground: {
    position: 'absolute',
    left: 256,
    top: 0,
    bottom: 0,
    right: 0,
    zIndex: 1
  },
  tocArea: {
    position: 'absolute',
    left: 0,
    top: 0,
    bottom: 0,
    zIndex: 0,
    width: 256,
    overflowY: 'auto',
    WebkitOverflowScrolling: 'touch',
    background: 'var(--muted)',
    padding: '10px 0'
  },
  tocAreaButton: {
    userSelect: 'none',
    appearance: 'none',
    background: 'none',
    border: 'none',
    display: 'block',
    fontFamily: 'sans-serif',
    width: '100%',
    fontSize: '.9em',
    textAlign: 'left',
    padding: '.9em 1em',
    borderBottom: '1px solid var(--border)',
    color: 'var(--muted-foreground)',
    boxSizing: 'border-box',
    // Outline removed because the consuming component adds a
    // `:focus-visible` ring via inline focus handlers below.
    outline: 'none',
    cursor: 'pointer'
  },
  tocButton: {
    background: 'none',
    border: 'none',
    width: 32,
    height: 32,
    position: 'absolute',
    top: 8,
    left: 78,
    borderRadius: 2,
    // Focus ring is added on TocToggleButton via `onFocus`/`onBlur` handlers
    // (see TocToggleButton.tsx) — outline omitted here so the ring style we
    // apply there is the only painted outline.
    cursor: 'pointer',
    color: 'var(--foreground)'
  },
  tocButtonExpanded: {
    background: 'var(--muted)'
  },
  tocButtonBar: {
    position: 'absolute',
    width: '60%',
    background: 'var(--foreground)',
    height: 2,
    left: '50%',
    margin: '-1px -30%',
    top: '50%',
    transition: 'all var(--motion-duration, .5s) ease'
  },
  tocButtonBarTop: {
    top: '35%'
  },
  tocButtonBottom: {
    top: '66%'
  },
  loadingView: {
    position: 'absolute',
    top: '50%',
    left: '10%',
    right: '10%',
    color: 'var(--muted-foreground)',
    textAlign: 'center',
    marginTop: '-.5em'
  },
  errorView: {
    position: 'absolute',
    top: '50%',
    left: '10%',
    right: '10%',
    color: 'var(--destructive)',
    textAlign: 'center',
    marginTop: '-.5em'
  }
}
