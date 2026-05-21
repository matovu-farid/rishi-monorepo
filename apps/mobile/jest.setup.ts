/**
 * Jest setup — set the React act-environment flag so react-test-renderer
 * stops printing warnings about updates not being wrapped in `act(...)`.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
;(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true
