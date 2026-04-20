/// Generates the JavaScript init script injected into the webview before
/// app code loads via Tauri's `js_init_script`. Sets up `__tauriCypress`
/// global, provides mock-aware invoke, and connects to the plugin's
/// WebSocket server.
///
/// SECURITY NOTE: This code runs exclusively in the test harness context behind
/// a compile-time feature flag (test-harness). The dynamic evaluation in
/// `executeTestScript` is intentional — the trusted runner sends test scripts
/// over localhost-only WebSocket. Only active behind the feature flag.
pub fn generate_init_script(ws_port: u16) -> String {
    format!(
        r#"
(function() {{
  // Use window-level storage so state persists across re-injections
  if (!window.__tauriCypressState) {{
    window.__tauriCypressState = {{
      mocks: new Map(),
      interceptors: new Map(),
      ipcLog: [],
      snapshotHistory: [],
      autoSnapshotEnabled: true,
    }};
  }}
  var mocks = window.__tauriCypressState.mocks;
  var interceptors = window.__tauriCypressState.interceptors;
  var ipcLog = window.__tauriCypressState.ipcLog;
  var snapshotHistory = window.__tauriCypressState.snapshotHistory;
  var autoSnapshotEnabled = window.__tauriCypressState.autoSnapshotEnabled;

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

  // Lightweight canvas-to-PNG capture via foreignObject SVG
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

    captureScreenshot().then(function(screenshotData) {{
      snapshot.screenshot = screenshotData;
      if (ws && ws.readyState === WebSocket.OPEN) {{
        ws.send(JSON.stringify({{ type: "snapshot", data: snapshot }}));
      }}
    }});

    return snapshot;
  }}

  // Mock-aware invoke: checks mocks/interceptors first, falls back to real Tauri invoke.
  // This is called by test scripts instead of window.__TAURI_INTERNALS__.invoke
  // to avoid the problem of Tauri overwriting our monkey-patch.
  async function invokeWithMocks(cmd, args, options) {{
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
      // Call the real Tauri invoke
      response = await window.__TAURI_INTERNALS__.invoke(cmd, args, options);
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

    if (autoSnapshotEnabled && !cmd.startsWith("plugin:test-harness|")) {{
      takeSnapshot("after:" + cmd, cmd);
    }}

    return response;
  }}

  var ws = null;
  var wsReconnectAttempts = 0;
  var WS_MAX_RECONNECT = 3;

  function connectWebSocket() {{
    ws = new WebSocket("ws://127.0.0.1:{port}");

    ws.onopen = function() {{
      wsReconnectAttempts = 0;
      console.log("[tauri-cypress] WebSocket connected to port {port}");
    }};

    ws.onmessage = function(event) {{
      try {{
        var msg = JSON.parse(event.data);
        console.log("[tauri-cypress] Received message type:", msg.type);
        if (msg.type === "exec") {{
          console.log("[tauri-cypress] Executing test:", msg.test_id);
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

    ws.onerror = function(e) {{
      console.error("[tauri-cypress] WebSocket error:", e);
    }};
  }}

  function sendIpcLog(entry) {{
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "ipc", data: entry }}));
    }}
  }}

  // Test script execution — intentionally uses dynamic evaluation.
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
            error: (e && e.message) ? e.message : String(e),
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
      // Mock-aware invoke — test scripts should use this instead of
      // window.__TAURI_INTERNALS__.invoke to ensure mocks are checked
      invoke: invokeWithMocks,
      getState: async function(key) {{
        return invokeWithMocks(
          "plugin:test-harness|get_app_state",
          {{ key: key }}
        );
      }},
      callHelper: async function(name, args) {{
        return invokeWithMocks(
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

  connectWebSocket();
}})();
"#,
        port = ws_port
    )
}
