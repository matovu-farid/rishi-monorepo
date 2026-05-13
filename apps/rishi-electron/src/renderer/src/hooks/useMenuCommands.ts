import { useEffect } from 'react'

export type MenuCommandHandlers = Partial<Record<string, (arg?: unknown) => void>>

export function useMenuCommands(handlers: MenuCommandHandlers): void {
  useEffect(() => {
    const e = (
      window as unknown as {
        electron: {
          onMenuCommand: (cb: (c: { command: string; arg?: unknown }) => void) => () => void
        }
      }
    ).electron
    if (!e?.onMenuCommand) return
    const dispose = e.onMenuCommand(({ command, arg }) => {
      const h = handlers[command]
      if (h) h(arg)
    })
    return dispose
  }, [handlers])
}
