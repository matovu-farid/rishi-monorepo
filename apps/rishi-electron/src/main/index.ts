import { app, BrowserWindow, shell, protocol, net } from "electron";
import { join } from "path";
import { pathToFileURL } from "url";
import { electronApp, optimizer, is } from "@electron-toolkit/utils";
import { registerAllIpcHandlers } from "./ipc/index.js";
import { initDatabase } from "./database/index.js";
import { initVectorDb } from "./vectordb/index.js";

let mainWindow: BrowserWindow | null = null;

const DEEP_LINK_PROTOCOL = "rishi-electron";

/**
 * Forward a deep-link URL to the renderer so the useHydrateAuth hook can
 * handle OAuth callbacks.
 */
function handleDeepLink(url: string): void {
  if (!url.includes("auth/callback")) return;
  // Focus/restore the main window
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
    mainWindow.webContents.send("deep-link", url);
  }
}

/**
 * Register a custom protocol `local-file://` that serves files from the
 * local filesystem. This replaces Tauri's `asset://` protocol and is the
 * Electron best practice for loading local files (PDFs, EPUBs, images)
 * into the renderer without disabling web security.
 *
 * Usage in renderer: convert a path like `/Users/x/book.pdf` to
 * `local-file:///Users/x/book.pdf`
 */
function registerLocalFileProtocol(): void {
  protocol.handle("local-file", (request) => {
    // Strip the protocol prefix to get the file path
    // local-file:///Users/x/file.pdf -> /Users/x/file.pdf
    const filePath = decodeURIComponent(
      request.url.replace("local-file://", "")
    );
    return net.fetch(pathToFileURL(filePath).href);
  });
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1024,
    height: 770,
    minWidth: 800,
    minHeight: 600,
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 15, y: 10 },
    show: false,
    webPreferences: {
      preload: join(__dirname, "../preload/index.js"),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false,
      // epub.js creates about:srcdoc iframes that need script execution.
      // webSecurity must be false so Chromium doesn't sandbox those frames.
      // Security is maintained via contextIsolation + preload + CSP.
      webSecurity: false,
    },
  });

  mainWindow.on("ready-to-show", () => {
    mainWindow?.show();
  });

  mainWindow.webContents.setWindowOpenHandler((details) => {
    const url = details.url;
    // Redirect Clerk OAuth popups to system browser so the user can
    // leverage saved browser sessions (Google, GitHub, etc.)
    if (url.includes("clerk") || url.includes("accounts.dev")) {
      shell.openExternal(url);
      return { action: "deny" };
    }
    if (url.startsWith("http:") || url.startsWith("https:") || url.startsWith("mailto:")) {
      shell.openExternal(url);
    }
    return { action: "deny" };
  });

  if (is.dev && process.env["ELECTRON_RENDERER_URL"]) {
    mainWindow.loadURL(process.env["ELECTRON_RENDERER_URL"]);
  } else {
    mainWindow.loadFile(join(__dirname, "../renderer/index.html"));
  }
}

// macOS: handle deep link when app is already running
app.on("open-url", (event, url) => {
  event.preventDefault();
  handleDeepLink(url);
});

// Ensure single instance so deep links always reach the existing window
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
} else {
  // Windows/Linux: second instance receives the deep link URL
  app.on("second-instance", (_event, argv) => {
    const url = argv.find((arg) => arg.startsWith(`${DEEP_LINK_PROTOCOL}://`));
    if (url) handleDeepLink(url);
  });
}

app.whenReady().then(async () => {
  electronApp.setAppUserModelId("org.fidexa.rishi");

  // Register as the handler for rishi-electron:// URLs
  app.setAsDefaultProtocolClient(DEEP_LINK_PROTOCOL);

  // Register custom protocol for serving local files to renderer
  registerLocalFileProtocol();

  app.on("browser-window-created", (_, window) => {
    optimizer.watchWindowShortcuts(window);
  });

  // Initialize backend services
  await initDatabase();
  initVectorDb();
  registerAllIpcHandlers();

  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

export { mainWindow };
