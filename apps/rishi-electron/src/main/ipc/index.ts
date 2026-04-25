import { registerBookHandlers } from "./books.js";
import { registerChunkHandlers } from "./chunks.js";
import { registerSearchHandlers } from "./search.js";
import { registerVectorHandlers } from "./vectors.js";
import { registerFormatHandlers } from "./formats.js";
import { registerFsHandlers } from "./fs.js";
import { registerScannerHandlers } from "./scanner.js";
import { registerAuthHandlers } from "./auth.js";
import { registerDebugHandlers } from "./debug.js";
import { registerStoreHandlers } from "./store.js";
import { registerUtilHandlers } from "./util.js";
import { registerDbHandlers } from "./db.js";
import { registerDialogHandlers } from "./dialog.js";

export function registerAllIpcHandlers(): void {
  registerBookHandlers();
  registerChunkHandlers();
  registerSearchHandlers();
  registerVectorHandlers();
  registerFormatHandlers();
  registerFsHandlers();
  registerScannerHandlers();
  registerAuthHandlers();
  registerDebugHandlers();
  registerStoreHandlers();
  registerUtilHandlers();
  registerDbHandlers();
  registerDialogHandlers();
}
