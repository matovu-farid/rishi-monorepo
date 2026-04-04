import { invoke } from "@tauri-apps/api/core";

export const isDev = async () => {
  return await invoke<boolean>("is_dev");
};
