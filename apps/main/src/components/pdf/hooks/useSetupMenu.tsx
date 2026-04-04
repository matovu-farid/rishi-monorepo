import { useEffect } from "react";
import {
  Menu as TauriMenu,
  Submenu,
  CheckMenuItem,
} from "@tauri-apps/api/menu";
import { ensureTray, setTrayMenu, clearTrayMenu } from "@components/lib/tray";

// Import required CSS for text and annotation layers

import { isDualPageAtom } from "@components/pdf/atoms/paragraph-atoms";
import { customStore } from "@/stores/jotai";
import { useAtomValue } from "jotai";

export function useSetupMenu() {
  // Setup menu on mount/unmount
  useEffect(() => {
    let previousAppMenu: TauriMenu | null = null;
    let viewSubmenu: Submenu | null = null;
    let twoPagesItem: CheckMenuItem | null = null;

    const setupMenu = async () => {
      try {
        // Get the default app menu
        const defaultMenu = await TauriMenu.default();
        previousAppMenu = await defaultMenu.setAsAppMenu();

        // Find or create View submenu
        viewSubmenu = (await defaultMenu.get("view")) as Submenu | null;
        if (!viewSubmenu) {
          viewSubmenu = await Submenu.new({
            id: "pdf",
            text: "pdf",
          });
          await defaultMenu.append(viewSubmenu);
        }

        // Remove existing two_pages item if it exists
        const existingItem = await viewSubmenu.get("two_pages");
        if (existingItem) {
          await viewSubmenu.remove(existingItem);
        }

        // Create CheckMenuItem for Two Pages
        // The action will toggle the current state by reading from the atom store
        twoPagesItem = await CheckMenuItem.new({
          id: "two_pages",
          text: "Two Pages",
          checked: customStore.get(isDualPageAtom),
          action: () => {
            // Read current value from atom store and toggle
            const current = customStore.get(isDualPageAtom);
            customStore.set(isDualPageAtom, !current);
          },
        });

        await viewSubmenu.append(twoPagesItem);

        // Set the modified menu as app menu
        await defaultMenu.setAsAppMenu();

        // Also set tray menu
        await ensureTray();
        await setTrayMenu(defaultMenu);
      } catch (error) {
        console.error("Error setting up menu:", error);
        // ignore tray/menu errors in environments that don't support them
      }
    };

    void setupMenu();

    return () => {
      void (async () => {
        try {
          // Remove the two_pages item on cleanup
          if (viewSubmenu && twoPagesItem) {
            await viewSubmenu.remove(twoPagesItem);
          }
          // Restore previous menu
          if (previousAppMenu) {
            await previousAppMenu.setAsAppMenu();
          } else {
            const def = await TauriMenu.default();
            await def.setAsAppMenu();
          }
          await clearTrayMenu();
        } catch (error) {
          console.error("Error cleaning up menu:", error);
        }
      })();
    };
  }, []); // Only run on mount/unmount, not when isDualPage changes
    // Update checkbox state when isDualPage changes
    const isDualPage = useAtomValue(isDualPageAtom);
    useEffect(() => {
      void (async () => {
        try {
          const defaultMenu = await TauriMenu.default();
          const viewSubmenu = (await defaultMenu.get("view")) as Submenu | null;
          if (viewSubmenu) {
            const twoPagesItem = (await viewSubmenu.get(
              "two_pages"
            )) as CheckMenuItem | null;
            if (twoPagesItem) {
              await twoPagesItem.setChecked(isDualPage);
            }
          }
        } catch {
          // ignore errors
        }
      })();
    }, [isDualPage]);
}
