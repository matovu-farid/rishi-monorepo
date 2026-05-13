import type { MenuItemConstructorOptions } from 'electron'
import { buildMenu } from './menuBuilder'
import type { MenuCommand, MenuContext } from './commands'

export type SetApplicationMenu = (template: MenuItemConstructorOptions[]) => void
export type SendToFocused = (command: MenuCommand) => void

export class MenuInstaller {
  private lastHash: string | null = null
  private lastTemplate: MenuItemConstructorOptions[] | null = null

  constructor(
    private setMenu: SetApplicationMenu,
    private send: SendToFocused
  ) {}

  setContext(ctx: MenuContext): void {
    const h = hashContext(ctx)
    if (h === this.lastHash) return
    this.lastHash = h
    const tpl = buildMenu(ctx, (c) => this.send(c))
    this.lastTemplate = tpl
    this.setMenu(tpl)
  }

  currentTemplate(): MenuItemConstructorOptions[] | null {
    return this.lastTemplate
  }
}

export function hashContext(ctx: MenuContext): string {
  return JSON.stringify(ctx)
}
