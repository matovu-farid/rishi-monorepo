/// Generates the JavaScript init script injected into the webview before
/// app code loads via Tauri's `js_init_script`. Sets up `__tauriCypress`
/// global, monkey-patches `invoke()` for IPC interception, and connects
/// to the plugin's WebSocket server. Includes auto-snapshot capture after
/// each IPC command with lightweight canvas-to-PNG via foreignObject SVG.
///
/// SECURITY NOTE: This code runs exclusively in the test harness context behind
/// a compile-time feature flag (test-harness). The `new Function()` usage in
/// `executeTestScript` is intentional — it evaluates test scripts sent from the
/// trusted test runner over localhost-only WebSocket. This is the core mechanism
/// by which the test runner executes test code inside the app-under-test's webview.
/// The feature flag ensures this code never ships in production builds.
pub fn generate_init_script(ws_port: u16) -> String {
    format!(
        r#"
(function() {{
  var mocks = new Map();
  var interceptors = new Map();
  var ipcLog = [];
  var snapshotHistory = [];
  var autoSnapshotEnabled = true;

  function mockCommand(name, response) {{
    mocks.set(name, response);
  }}

  function interceptCommand(name, handler) {{
    interceptors.set(name, handler);
  }}

  function removeMock(name) {{
    mocks.delete(name);
  }}

  function clearMocks() {{
    mocks.clear();
    interceptors.clear();
  }}

  // Lightweight canvas-to-PNG capture via foreignObject SVG.
  // Avoids heavy html2canvas dependency — ~30 lines of JS.
  function captureScreenshot() {{
    return new Promise(function(resolve) {{
      try {{
        var body = document.body;
        var width = body.scrollWidth || 1280;
        var height = body.scrollHeight || 800;

        var svgData = '<svg xmlns="http://www.w3.org/2000/svg" width="' + width + '" height="' + height + '">' +
          '<foreignObject width="100%" height="100%">' +
          new XMLSerializer().serializeToString(document.documentElement) +
          '</foreignObject></svg>';

        var img = new Image();
        var svgBlob = new Blob([svgData], {{ type: 'image/svg+xml;charset=utf-8' }});
        var url = URL.createObjectURL(svgBlob);

        img.onload = function() {{
          var canvas = document.createElement('canvas');
          canvas.width = Math.min(width, 1920);
          canvas.height = Math.min(height, 1080);
          var ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          URL.revokeObjectURL(url);
          resolve(canvas.toDataURL('image/png', 0.8));
        }};

        img.onerror = function() {{
          URL.revokeObjectURL(url);
          resolve(null);
        }};

        img.src = url;
      }} catch (e) {{
        resolve(null);
      }}
    }});
  }}

  function takeSnapshot(label, commandName) {{
    var snapshot = {{
      label: label,
      html: document.documentElement.outerHTML,
      url: window.location.href,
      timestamp_ms: Date.now(),
      command_name: commandName || null,
      screenshot: null
    }};
    snapshotHistory.push(snapshot);

    // Capture screenshot asynchronously, send once ready
    captureScreenshot().then(function(screenshotData) {{
      snapshot.screenshot = screenshotData;
      if (ws && ws.readyState === WebSocket.OPEN) {{
        ws.send(JSON.stringify({{ type: "snapshot", data: snapshot }}));
      }}
    }});

    return snapshot;
  }}

  var originalInvoke = null;

  function patchInvoke() {{
    if (!window.__TAURI_INTERNALS__ || !window.__TAURI_INTERNALS__.invoke) {{
      setTimeout(patchInvoke, 1);
      return;
    }}
    if (originalInvoke) return;

    originalInvoke = window.__TAURI_INTERNALS__.invoke.bind(
      window.__TAURI_INTERNALS__
    );

    window.__TAURI_INTERNALS__.invoke = async function(cmd, args, options) {{
      var startTime = Date.now();
      var response;
      var mocked = false;

      if (mocks.has(cmd)) {{
        response = mocks.get(cmd);
        mocked = true;
      }} else if (interceptors.has(cmd)) {{
        try {{
          response = await interceptors.get(cmd)(args);
          mocked = true;
        }} catch (e) {{
          var entry = {{
            command: cmd,
            args: args || null,
            response: null,
            mocked: true,
            duration_ms: Date.now() - startTime,
            timestamp_ms: startTime
          }};
          ipcLog.push(entry);
          sendIpcLog(entry);
          throw e;
        }}
      }} else {{
        response = await originalInvoke(cmd, args, options);
      }}

      var entry = {{
        command: cmd,
        args: args || null,
        response: response,
        mocked: mocked,
        duration_ms: Date.now() - startTime,
        timestamp_ms: startTime
      }};
      ipcLog.push(entry);
      sendIpcLog(entry);

      // Auto-capture snapshot after each IPC command (skip plugin's own commands)
      if (autoSnapshotEnabled && !cmd.startsWith("plugin:test-harness|")) {{
        takeSnapshot("after:" + cmd, cmd);
      }}

      return response;
    }};
  }}

  var ws = null;
  var wsReconnectAttempts = 0;
  var WS_MAX_RECONNECT = 3;

  function connectWebSocket() {{
    ws = new WebSocket("ws://127.0.0.1:{port}");

    ws.onopen = function() {{
      wsReconnectAttempts = 0;
    }};

    ws.onmessage = function(event) {{
      try {{
        var msg = JSON.parse(event.data);
        if (msg.type === "exec") {{
          executeTestScript(msg.script, msg.test_id);
        }}
      }} catch (e) {{
        console.error("[tauri-cypress] Failed to parse message:", e);
      }}
    }};

    ws.onclose = function() {{
      if (wsReconnectAttempts < WS_MAX_RECONNECT) {{
        wsReconnectAttempts++;
        setTimeout(connectWebSocket, 500);
      }}
    }};

    ws.onerror = function() {{}};
  }}

  function sendIpcLog(entry) {{
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "ipc", data: entry }}));
    }}
  }}

  // Test script execution — intentionally uses dynamic evaluation.
  // This is the core test runner mechanism: the trusted runner sends test
  // scripts over localhost WebSocket, which are evaluated in the app's webview.
  // Only active behind the test-harness feature flag (never in production).
  async function executeTestScript(script, testId) {{
    var startTime = Date.now();
    try {{
      var AsyncFunction = Object.getPrototypeOf(async function(){{}}).constructor;
      var fn = new AsyncFunction("__tauriCypress", script);
      await fn(window.__tauriCypress);
      if (ws && ws.readyState === WebSocket.OPEN) {{
        ws.send(JSON.stringify({{
          type: "result",
          data: {{
            test_id: testId,
            status: "passed",
            assertions: [],
            error: null,
            duration_ms: Date.now() - startTime
          }}
        }}));
      }}
    }} catch (e) {{
      if (ws && ws.readyState === WebSocket.OPEN) {{
        ws.send(JSON.stringify({{
          type: "result",
          data: {{
            test_id: testId,
            status: "failed",
            assertions: [],
            error: e.message || String(e),
            duration_ms: Date.now() - startTime
          }}
        }}));
      }}
    }}
  }}

  window.__tauriCypress = {{
    bridge: {{
      mockCommand: mockCommand,
      interceptCommand: interceptCommand,
      removeMock: removeMock,
      clearMocks: clearMocks,
      getState: async function(key) {{
        if (!originalInvoke) return null;
        return originalInvoke(
          "plugin:test-harness|get_app_state",
          {{ key: key }}
        );
      }},
      callHelper: async function(name, args) {{
        if (!originalInvoke) return null;
        return originalInvoke(
          "plugin:test-harness|call_helper",
          {{ name: name, args: args || null }}
        );
      }}
    }},
    ipc: {{
      intercept: interceptCommand,
      passthrough: function(name) {{
        interceptors.delete(name);
        mocks.delete(name);
      }},
      get log() {{ return ipcLog.slice(); }}
    }},
    snapshot: {{
      take: takeSnapshot,
      get history() {{ return snapshotHistory.slice(); }},
      setAutoCapture: function(enabled) {{ autoSnapshotEnabled = enabled; }}
    }},
    __exec: executeTestScript
  }};

  patchInvoke();
  connectWebSocket();
}})();
"#,
        port = ws_port
    )
}
