import { isDev } from "@/utils/is_dev";
import config from "../config.json";
export const shouldDebug = async (): Promise<boolean> => {
  if (await isDev()) {
    return config.development.player.recordPlayingState;
  }
  return config.production.player.recordPlayingState;
};
