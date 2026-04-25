import type { ElectronAPI } from "../../src/preload/types";

declare global {
  interface Window {
    electron: ElectronAPI;
  }
}
