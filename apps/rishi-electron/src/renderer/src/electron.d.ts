// Global type declaration for the Electron API exposed via contextBridge
import type { ElectronAPI } from "../../preload/types";

declare global {
  interface Window {
    electron: ElectronAPI;
  }
}

export {};
