import { registerBookHandlers } from './books.js'
import { registerChunkHandlers } from './chunks.js'
import { registerSearchHandlers } from './search.js'
import { registerVectorHandlers } from './vectors.js'
import { registerFormatHandlers } from './formats.js'
import { registerFsHandlers } from './fs.js'
import { registerScannerHandlers } from './scanner.js'
import { registerAuthHandlers } from './auth.js'
import { registerDebugHandlers } from './debug.js'
import { registerStoreHandlers } from './store.js'
import { registerUtilHandlers } from './util.js'

import { registerDialogHandlers } from './dialog.js'
import { registerBookmarkHandlers } from './bookmarks.js'
import { registerHighlightHandlers } from './highlights.js'
import { registerConversationHandlers } from './conversations.js'
import { registerBooksExtraHandlers } from './books-extra.js'
import { registerSyncHandlers } from './sync.js'
import { registerUpdaterHandlers } from './updater.js'

export function registerAllIpcHandlers(): void {
  registerBookHandlers()
  registerChunkHandlers()
  registerSearchHandlers()
  registerVectorHandlers()
  registerFormatHandlers()
  registerFsHandlers()
  registerScannerHandlers()
  registerAuthHandlers()
  registerDebugHandlers()
  registerStoreHandlers()
  registerUtilHandlers()
  registerDialogHandlers()
  registerBookmarkHandlers()
  registerHighlightHandlers()
  registerConversationHandlers()
  registerBooksExtraHandlers()
  registerSyncHandlers()
  registerUpdaterHandlers()
}
