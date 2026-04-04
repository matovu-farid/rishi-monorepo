import { TrayIcon } from "@tauri-apps/api/tray";
import { Menu } from "@tauri-apps/api/menu";

let trayInstance: TrayIcon | null = null;
let creatingPromise: Promise<TrayIcon> | null = null;

export async function ensureTray(): Promise<TrayIcon> {
  if (trayInstance) return trayInstance;
  if (!creatingPromise) {
    creatingPromise = (async () => {
      const tray = await TrayIcon.new({
        // show menu on left click as well
        menuOnLeftClick: true,
      });
      trayInstance = tray;
      return tray;
    })();
  }
  return creatingPromise;
}

export async function setTrayMenu(menu: Menu): Promise<void> {
  const tray = await ensureTray();
  await tray.setMenu(menu);
}

export async function clearTrayMenu(): Promise<void> {
  if (!trayInstance && !creatingPromise) return;
  const tray = await ensureTray();
  const empty = await Menu.new({ items: [] });
  await tray.setMenu(empty);
}
