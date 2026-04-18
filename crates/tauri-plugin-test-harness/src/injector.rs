/// Generates the JavaScript init script injected into the webview before
/// app code loads via Tauri's `js_init_script`. Sets up `__tauriCypress`
/// global, monkey-patches `invoke()` for IPC interception, and connects
/// to the plugin's WebSocket server.
pub fn generate_init_script(ws_port: u16) -> String {
    format!(
        r#"
(function() {{
  var mocks = new Map();
  var interceptors = new Map();
  var ipcLog = [];
  var snapshotHistory = [];

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

  function takeSnapshot(label) {{
    var snapshot = {{
      label: label,
      html: document.documentElement.outerHTML,
      url: window.location.href,
      timestamp_ms: Date.now()
    }};
    snapshotHistory.push(snapshot);
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "snapshot", data: snapshot }}));
    }}
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

  async function executeTestScript(script, testId) {{
    var startTime = Date.now();
    try {{
      var fn = new Function("__tauriCypress", script);
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
      get history() {{ return snapshotHistory.slice(); }}
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
