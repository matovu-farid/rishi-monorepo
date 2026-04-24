/// Generates the JavaScript init script injected into the webview before
/// app code loads via Tauri's `js_init_script`. Sets up `__tauriCypress`
/// global, provides mock-aware invoke, and connects to the plugin's
/// WebSocket server.
///
/// Also provides Cypress-like `cy`, `describe`, `it`, `beforeEach`,
/// `afterEach` globals so test scripts can use them without imports.
///
/// SECURITY NOTE: This code runs exclusively in the test harness context behind
/// a compile-time feature flag (test-harness). The dynamic evaluation in
/// `executeTestScript` is intentional — the trusted runner sends test scripts
/// over localhost-only WebSocket. Only active behind the feature flag.
pub fn generate_init_script(ws_port: u16) -> String {
    format!(
        r#"
(function() {{
  try {{
  // Use window-level storage so state persists across re-injections
  if (!window.__tauriCypressState) {{
    window.__tauriCypressState = {{
      mocks: new Map(),
      interceptors: new Map(),
      ipcLog: [],
      snapshotHistory: [],
      autoSnapshotEnabled: false,
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

  function captureHtmlWithStyles() {{
    try {{
      var styles = "";
      for (var i = 0; i < document.styleSheets.length; i++) {{
        try {{
          var sheet = document.styleSheets[i];
          var rules = sheet.cssRules || sheet.rules;
          if (rules) {{
            for (var j = 0; j < rules.length; j++) {{
              styles += rules[j].cssText + "\n";
            }}
          }}
        }} catch (e) {{
          // Cross-origin stylesheet, skip
        }}
      }}
      var html = document.documentElement.outerHTML;
      // Inject collected styles into <head>
      var styleTag = "<style>" + styles + "</style>";
      html = html.replace("</head>", styleTag + "</head>");
      return html;
    }} catch (e) {{
      return document.documentElement.outerHTML;
    }}
  }}

  function takeSnapshot(label, commandName, lightweight) {{
    var snapshot = {{
      label: label,
      html: lightweight ? "" : captureHtmlWithStyles(),
      url: window.location.href,
      timestamp_ms: Date.now(),
      command_name: commandName || null,
      screenshot: null
    }};
    snapshotHistory.push(snapshot);

    // Send snapshot immediately so the runner gets it
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "snapshot", data: snapshot }}));
    }}

    return snapshot;
  }}

  // Mock-aware invoke: checks mocks/interceptors first, falls back to real Tauri invoke.
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
      takeSnapshot("after:" + cmd, cmd, true);
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
      // Signal to the runner that the webview is ready to receive tests.
      // Send repeatedly until we receive an exec (meaning the runner is listening).
      ws.send(JSON.stringify({{ type: "ready" }}));
      window.__tauriCypressReadyInterval = setInterval(function() {{
        if (ws && ws.readyState === WebSocket.OPEN) {{
          ws.send(JSON.stringify({{ type: "ready" }}));
        }}
      }}, 500);
    }};

    ws.onmessage = function(event) {{
      try {{
        var msg = JSON.parse(event.data);
        if (msg.type === "exec") {{
          // Stop sending ready signals — the runner is listening
          if (window.__tauriCypressReadyInterval) {{
            clearInterval(window.__tauriCypressReadyInterval);
            window.__tauriCypressReadyInterval = null;
          }}
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

  function sendResult(data) {{
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "result", data: data }}));
    }}
  }}

  // ============================================================
  // Test runner: describe / it / beforeEach / afterEach
  // ============================================================
  var __runner = {{
    blocks: [],
    stack: [],
    current: function() {{
      return this.stack.length > 0 ? this.stack[this.stack.length - 1] : null;
    }},
    reset: function() {{
      this.blocks = [];
      this.stack = [];
    }}
  }};

  function describe(name, fn) {{
    var block = {{
      name: name,
      tests: [],
      beforeEachFns: [],
      afterEachFns: [],
      children: []
    }};
    var parent = __runner.current();
    if (parent) {{
      parent.children.push(block);
    }} else {{
      __runner.blocks.push(block);
    }}
    __runner.stack.push(block);
    fn();
    __runner.stack.pop();
  }}

  function it(name, fn) {{
    var parent = __runner.current();
    if (!parent) {{
      throw new Error("it() must be called inside describe()");
    }}
    parent.tests.push({{ name: name, fn: fn }});
  }}

  function beforeEach(fn) {{
    var parent = __runner.current();
    if (!parent) {{
      throw new Error("beforeEach() must be called inside describe()");
    }}
    parent.beforeEachFns.push(fn);
  }}

  function afterEach(fn) {{
    var parent = __runner.current();
    if (!parent) {{
      throw new Error("afterEach() must be called inside describe()");
    }}
    parent.afterEachFns.push(fn);
  }}

  async function runBlock(block, path, parentBeforeEach, parentAfterEach) {{
    var fullPath = path ? path + " > " + block.name : block.name;
    var allBefore = parentBeforeEach.concat(block.beforeEachFns);
    var allAfter = parentAfterEach.concat(block.afterEachFns);
    var results = [];

    for (var i = 0; i < block.tests.length; i++) {{
      var test = block.tests[i];
      var testId = fullPath + " > " + test.name;
      var startTime = Date.now();
      try {{
        for (var b = 0; b < allBefore.length; b++) await allBefore[b]();
        await test.fn();
        // Auto-run any pending cy chain
        if (window.cy && window.cy.__hasPendingChain()) {{
          await window.cy.__run();
        }}
        for (var a = 0; a < allAfter.length; a++) await allAfter[a]();
        results.push({{
          test_id: testId,
          status: "passed",
          assertions: [],
          error: null,
          duration_ms: Date.now() - startTime
        }});
      }} catch (e) {{
        try {{ for (var a2 = 0; a2 < allAfter.length; a2++) await allAfter[a2](); }} catch(_) {{}}
        results.push({{
          test_id: testId,
          status: "failed",
          assertions: [],
          error: (e && e.message) ? e.message : String(e),
          duration_ms: Date.now() - startTime
        }});
      }}
    }}

    for (var c = 0; c < block.children.length; c++) {{
      var childResults = await runBlock(block.children[c], fullPath, allBefore, allAfter);
      results = results.concat(childResults);
    }}

    return results;
  }}

  async function runAllTests() {{
    var allResults = [];
    for (var i = 0; i < __runner.blocks.length; i++) {{
      var results = await runBlock(__runner.blocks[i], "", [], []);
      allResults = allResults.concat(results);
    }}
    return allResults;
  }}

  // ============================================================
  // Cypress-like cy API
  // ============================================================

  // Assertion matchers
  var matchers = new Map();

  function registerMatcher(name, fn) {{ matchers.set(name, fn); }}

  registerMatcher("exist", function(subject) {{
    return {{ passed: !!subject, actual: subject, expected: "to exist" }};
  }});
  registerMatcher("not.exist", function(subject) {{
    return {{ passed: !subject, actual: subject, expected: "to not exist" }};
  }});
  registerMatcher("be.visible", function(subject) {{
    var el = subject;
    if (!el || typeof el.getBoundingClientRect !== "function") return {{ passed: false, actual: null, expected: "visible element" }};
    var style = window.getComputedStyle(el);
    var rect = el.getBoundingClientRect();
    var visible = style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0" && rect.width > 0 && rect.height > 0;
    return {{ passed: visible, actual: style.display + "/" + style.visibility, expected: "visible" }};
  }});
  registerMatcher("be.hidden", function(subject) {{
    var r = matchers.get("be.visible")(subject);
    return {{ passed: !r.passed, actual: r.actual, expected: "hidden" }};
  }});
  registerMatcher("be.disabled", function(subject) {{
    return {{ passed: subject && subject.disabled === true, actual: subject && subject.disabled, expected: true }};
  }});
  registerMatcher("be.enabled", function(subject) {{
    return {{ passed: !subject || subject.disabled !== true, actual: subject && subject.disabled, expected: false }};
  }});
  registerMatcher("be.checked", function(subject) {{
    return {{ passed: subject && subject.checked === true, actual: subject && subject.checked, expected: true }};
  }});
  registerMatcher("have.text", function(subject, expected) {{
    var actual = subject ? (subject.textContent || "").trim() : "";
    return {{ passed: actual === expected, actual: actual, expected: expected }};
  }});
  registerMatcher("contain.text", function(subject, expected) {{
    var actual = subject ? (subject.textContent || "") : "";
    return {{ passed: actual.indexOf(expected) !== -1, actual: actual, expected: expected }};
  }});
  registerMatcher("have.value", function(subject, expected) {{
    var actual = subject ? subject.value : undefined;
    return {{ passed: actual === expected, actual: actual, expected: expected }};
  }});
  registerMatcher("have.class", function(subject, className) {{
    var has = subject && subject.classList && subject.classList.contains(className);
    return {{ passed: has, actual: subject && subject.className, expected: className }};
  }});
  registerMatcher("have.attr", function(subject, name, value) {{
    var actual = subject ? subject.getAttribute(name) : null;
    var passed = value === undefined ? actual !== null : actual === value;
    return {{ passed: passed, actual: actual, expected: value === undefined ? "attribute " + name : value }};
  }});
  registerMatcher("have.length", function(subject, expected) {{
    var actual = subject ? (subject.length !== undefined ? subject.length : 0) : 0;
    return {{ passed: actual === expected, actual: actual, expected: expected }};
  }});
  registerMatcher("include", function(subject, value) {{
    var has = false;
    if (Array.isArray(subject)) has = subject.indexOf(value) !== -1;
    else if (typeof subject === "string") has = subject.indexOf(value) !== -1;
    return {{ passed: has, actual: subject, expected: value }};
  }});
  registerMatcher("equal", function(subject, expected) {{
    var passed = JSON.stringify(subject) === JSON.stringify(expected);
    return {{ passed: passed, actual: subject, expected: expected }};
  }});
  registerMatcher("have.property", function(subject, prop, value) {{
    var has = subject && typeof subject === "object" && prop in subject;
    var actual = has ? subject[prop] : undefined;
    var passed = value === undefined ? has : actual === value;
    return {{ passed: passed, actual: actual, expected: value === undefined ? "property " + prop : value }};
  }});
  registerMatcher("have.css", function(subject, prop, value) {{
    var actual = subject ? window.getComputedStyle(subject).getPropertyValue(prop) : "";
    return {{ passed: actual === value, actual: actual, expected: value }};
  }});

  function applyMatcher(name, subject) {{
    var args = Array.prototype.slice.call(arguments, 2);
    var negated = false;
    var matcherName = name;
    if (matcherName.indexOf("not.") === 0 && !matchers.has(matcherName)) {{
      negated = true;
      matcherName = matcherName.substring(4);
    }}
    var fn = matchers.get(matcherName);
    if (!fn) throw new Error("Unknown matcher: " + name);
    var result = fn.apply(null, [subject].concat(args));
    if (negated) result.passed = !result.passed;
    return result;
  }}

  // Retry utility
  function cyRetry(fn, timeout) {{
    var interval = 50;
    timeout = timeout || 4000;
    return new Promise(function(resolve, reject) {{
      var startTime = Date.now();
      function attempt() {{
        try {{
          var result = fn();
          if (result && typeof result.then === "function") {{
            result.then(resolve, function(err) {{
              if (Date.now() - startTime >= timeout) return reject(err);
              setTimeout(attempt, interval);
            }});
          }} else {{
            resolve(result);
          }}
        }} catch (err) {{
          if (Date.now() - startTime >= timeout) return reject(err);
          setTimeout(attempt, interval);
        }}
      }}
      attempt();
    }});
  }}

  // CyChain: fluent command chain
  function CyChain(parentChain) {{
    this._queue = parentChain ? parentChain._queue : [];
    this._assertions = [];
  }}

  CyChain.prototype.enqueue = function(cmd) {{
    this._queue.push(cmd);
    return this;
  }};

  CyChain.prototype.execute = async function() {{
    var subject;
    var lastQueryIndex = -1;
    for (var i = 0; i < this._queue.length; i++) {{
      var cmd = this._queue[i];
      if (cmd.type === "query") {{
        lastQueryIndex = i;
        subject = await cmd.fn(subject);
      }} else if (cmd.type === "action") {{
        subject = await cmd.fn(subject);
      }} else if (cmd.type === "assertion") {{
        var queryIdx = lastQueryIndex;
        var queue = this._queue;
        if (queryIdx >= 0) {{
          var queryCmd = queue[queryIdx];
          var mid = queue.slice(queryIdx + 1, i);
          subject = await cyRetry(async function() {{
            var s = await queryCmd.fn(undefined);
            for (var m = 0; m < mid.length; m++) {{
              if (mid[m].type === "query") s = await mid[m].fn(s);
            }}
            return await cmd.fn(s);
          }}, cmd.timeout || 4000);
        }} else {{
          subject = await cmd.fn(subject);
        }}
        this._assertions.push({{ description: cmd.name, passed: true, expected: undefined, actual: subject }});
      }}
    }}
    return subject;
  }};

  // Child queries
  CyChain.prototype.find = function(sel) {{
    return this.enqueue({{ type: "query", name: "find(" + sel + ")", fn: function(s) {{
      return Array.from((s || document).querySelectorAll(sel));
    }} }});
  }};
  CyChain.prototype.first = function() {{
    return this.enqueue({{ type: "query", name: "first()", fn: function(s) {{
      if (!s || !s.length) throw new Error("first() requires at least one element");
      return s[0];
    }} }});
  }};
  CyChain.prototype.last = function() {{
    return this.enqueue({{ type: "query", name: "last()", fn: function(s) {{
      if (!s || !s.length) throw new Error("last() requires at least one element");
      return s[s.length - 1];
    }} }});
  }};
  CyChain.prototype.eq = function(index) {{
    return this.enqueue({{ type: "query", name: "eq(" + index + ")", fn: function(s) {{
      if (!s || index >= s.length) throw new Error("eq(" + index + "): index out of bounds");
      return s[index];
    }} }});
  }};

  // Actions
  CyChain.prototype.click = function() {{
    return this.enqueue({{ type: "action", name: "click()", fn: function(s) {{
      if (s) s.dispatchEvent(new MouseEvent("click", {{ bubbles: true, cancelable: true }}));
      return s;
    }} }});
  }};
  CyChain.prototype.type = function(text) {{
    return this.enqueue({{ type: "action", name: "type(" + text + ")", fn: function(s) {{
      if (s) {{
        s.value = text;
        s.dispatchEvent(new Event("input", {{ bubbles: true }}));
        s.dispatchEvent(new Event("change", {{ bubbles: true }}));
      }}
      return s;
    }} }});
  }};
  CyChain.prototype.clear = function() {{
    return this.enqueue({{ type: "action", name: "clear()", fn: function(s) {{
      if (s) {{
        s.value = "";
        s.dispatchEvent(new Event("input", {{ bubbles: true }}));
        s.dispatchEvent(new Event("change", {{ bubbles: true }}));
      }}
      return s;
    }} }});
  }};
  CyChain.prototype.check = function() {{
    return this.enqueue({{ type: "action", name: "check()", fn: function(s) {{
      if (s) {{
        s.checked = !s.checked;
        s.dispatchEvent(new Event("change", {{ bubbles: true }}));
      }}
      return s;
    }} }});
  }};
  CyChain.prototype.select = function(value) {{
    return this.enqueue({{ type: "action", name: "select(" + value + ")", fn: function(s) {{
      if (s) {{
        s.value = value;
        s.dispatchEvent(new Event("change", {{ bubbles: true }}));
      }}
      return s;
    }} }});
  }};

  // Assertions
  CyChain.prototype.should = function(matcher) {{
    var args = Array.prototype.slice.call(arguments, 1);
    return this.enqueue({{ type: "assertion", name: "should(" + matcher + ")", timeout: 4000, fn: function(subject) {{
      var result = applyMatcher.apply(null, [matcher, subject].concat(args));
      if (!result.passed) {{
        throw new Error("Expected to " + matcher +
          (args.length > 0 ? " " + JSON.stringify(args[0]) : "") +
          " but got " + JSON.stringify(result.actual));
      }}
      return subject;
    }} }});
  }};
  CyChain.prototype.and = CyChain.prototype.should;

  // Utilities
  CyChain.prototype.then = function(fn) {{
    return this.enqueue({{ type: "action", name: "then()", fn: function(s) {{ return fn(s); }} }});
  }};
  CyChain.prototype.wait = function(ms) {{
    return this.enqueue({{ type: "action", name: "wait(" + ms + ")", fn: function(s) {{
      return new Promise(function(r) {{ setTimeout(function() {{ r(s); }}, ms); }});
    }} }});
  }};
  CyChain.prototype.log = function(msg) {{
    return this.enqueue({{ type: "action", name: "log(" + msg + ")", fn: function(s) {{
      console.log("[cy] " + msg, s);
      return s;
    }} }});
  }};

  // cy global
  var cy = {{
    __currentChain: null,
    __run: async function() {{
      var chain = cy.__currentChain;
      cy.__currentChain = null;
      if (!chain) return {{ result: undefined, assertions: [] }};
      var result = await chain.execute();
      return {{ result: result, assertions: chain._assertions }};
    }},
    __hasPendingChain: function() {{
      return cy.__currentChain !== null;
    }},
    get: function(selector, options) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "query", name: "get(" + selector + ")", timeout: options && options.timeout, fn: function() {{
        var els = Array.from(document.querySelectorAll(selector));
        if (els.length === 0) throw new Error("Expected to find element: " + selector + ", but never found it.");
        return els.length === 1 ? els[0] : els;
      }} }});
      return chain;
    }},
    contains: function(text) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "query", name: "contains(" + text + ")", fn: function() {{
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
        var node = walker.nextNode();
        while (node) {{
          if (node.textContent && node.textContent.trim() === text.trim()) return node;
          node = walker.nextNode();
        }}
        throw new Error('No element containing "' + text + '"');
      }} }});
      return chain;
    }},
    // IPC commands
    mockCommand: function(name, response) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "mockCommand(" + name + ")", fn: function() {{ mockCommand(name, response); }} }});
      return chain;
    }},
    interceptCommand: function(name, handler) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "interceptCommand(" + name + ")", fn: function() {{ interceptCommand(name, handler); }} }});
      return chain;
    }},
    clearMocks: function() {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "clearMocks()", fn: function() {{ clearMocks(); }} }});
      return chain;
    }},
    invoke: function(cmd, args) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "invoke(" + cmd + ")", fn: function() {{ return invokeWithMocks(cmd, args); }} }});
      return chain;
    }},
    // Navigation
    visit: function(path) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "visit(" + path + ")", fn: function() {{ window.location.href = path; }} }});
      return chain;
    }},
    reload: function() {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "reload()", fn: function() {{ window.location.reload(); }} }});
      return chain;
    }},
    url: function() {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "query", name: "url()", fn: function() {{ return window.location.href; }} }});
      return chain;
    }},
    // Window commands via Tauri IPC
    window: function() {{
      return {{
        resize: function(w, h) {{
          var chain = new CyChain();
          cy.__currentChain = chain;
          chain.enqueue({{ type: "action", name: "window.resize", fn: function() {{
            return invokeWithMocks("plugin:test-harness|resize_window", {{ width: w, height: h }});
          }} }});
          return chain;
        }},
        minimize: function() {{
          var chain = new CyChain();
          cy.__currentChain = chain;
          chain.enqueue({{ type: "action", name: "window.minimize", fn: function() {{
            return invokeWithMocks("plugin:test-harness|minimize_window");
          }} }});
          return chain;
        }},
        maximize: function() {{
          var chain = new CyChain();
          cy.__currentChain = chain;
          chain.enqueue({{ type: "action", name: "window.maximize", fn: function() {{
            return invokeWithMocks("plugin:test-harness|maximize_window");
          }} }});
          return chain;
        }},
        size: function() {{
          var chain = new CyChain();
          cy.__currentChain = chain;
          chain.enqueue({{ type: "query", name: "window.size", fn: function() {{
            return invokeWithMocks("plugin:test-harness|get_window_size");
          }} }});
          return chain;
        }},
        position: function() {{
          var chain = new CyChain();
          cy.__currentChain = chain;
          chain.enqueue({{ type: "query", name: "window.position", fn: function() {{
            return invokeWithMocks("plugin:test-harness|get_window_position");
          }} }});
          return chain;
        }}
      }};
    }},
    // Snapshot
    snapshot: function(label) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "snapshot(" + label + ")", fn: function() {{ return takeSnapshot(label); }} }});
      return chain;
    }},
    // Utilities
    wait: function(ms) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "wait(" + ms + ")", fn: function() {{
        return new Promise(function(r) {{ setTimeout(r, ms); }});
      }} }});
      return chain;
    }},
    log: function(msg) {{
      var chain = new CyChain();
      cy.__currentChain = chain;
      chain.enqueue({{ type: "action", name: "log(" + msg + ")", fn: function() {{ console.log("[cy] " + msg); }} }});
      return chain;
    }}
  }};

  // ============================================================
  // Test script execution
  // ============================================================
  async function executeTestScript(script, testId) {{
    var startTime = Date.now();
    __runner.reset();

    try {{
      var AsyncFunction = Object.getPrototypeOf(async function(){{}}).constructor;
      var fn = new AsyncFunction("__tauriCypress", "cy", "describe", "it", "beforeEach", "afterEach", script);
      await fn(window.__tauriCypress, cy, describe, it, beforeEach, afterEach);

      // Auto-run any pending cy chain from top-level code
      if (cy.__hasPendingChain()) {{
        await cy.__run();
      }}
    }} catch (e) {{
      // If there are no describe/it blocks, treat as a single-script test (legacy mode)
      if (__runner.blocks.length === 0) {{
        sendResult({{
          test_id: testId,
          status: "failed",
          assertions: [],
          error: (e && e.message) ? e.message : String(e),
          duration_ms: Date.now() - startTime
        }});
        return;
      }}
    }}

    // If describe/it blocks were registered, run them individually
    if (__runner.blocks.length > 0) {{
      var results = await runAllTests();
      for (var i = 0; i < results.length; i++) {{
        sendResult(results[i]);
      }}
      // Send a summary result for the file
      var failed = results.filter(function(r) {{ return r.status === "failed"; }}).length;
      sendResult({{
        test_id: testId,
        status: failed > 0 ? "failed" : "passed",
        assertions: [],
        error: failed > 0 ? failed + " test(s) failed" : null,
        duration_ms: Date.now() - startTime
      }});
    }} else {{
      // Legacy mode: no describe/it, just a script
      sendResult({{
        test_id: testId,
        status: "passed",
        assertions: [],
        error: null,
        duration_ms: Date.now() - startTime
      }});
    }}
  }}

  // Expose globals
  window.__tauriCypress = {{
    bridge: {{
      mockCommand: mockCommand,
      interceptCommand: interceptCommand,
      removeMock: removeMock,
      clearMocks: clearMocks,
      invoke: invokeWithMocks,
      getState: async function(key) {{
        return invokeWithMocks("plugin:test-harness|get_app_state", {{ key: key }});
      }},
      callHelper: async function(name, args) {{
        return invokeWithMocks("plugin:test-harness|call_helper", {{ name: name, args: args || null }});
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

  // Expose Cypress-like globals
  window.cy = cy;
  window.describe = describe;
  window.it = it;
  window.beforeEach = beforeEach;
  window.afterEach = afterEach;

  connectWebSocket();
  }} catch(__initError) {{
    console.error("[tauri-cypress] FATAL init error:", __initError, __initError && __initError.stack);
    // Still try to connect WebSocket so we can report the error
    try {{ connectWebSocket(); }} catch(_e) {{}}
    // Send the error as a "ready" + error indicator
    window.__tauriCypressInitError = __initError ? __initError.message || String(__initError) : "unknown";
  }}
}})();
"#,
        port = ws_port
    )
}
