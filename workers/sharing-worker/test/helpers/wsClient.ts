import { SELF } from "cloudflare:test";

function b64url(s: string): string {
  // btoa is available in the Workers test runtime (cloudflare:test / miniflare).
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function openWs(wsUrl: string, jwt = "test", reconnect?: string) {
  // Mirror production client: base64url-encode bearer + reconnect token before
  // stuffing into Sec-WebSocket-Protocol (see workers/sharing-worker/src/wsCreds.ts).
  const protos = ["rishi.sharing.v1", `jwt.${b64url(jwt)}`].concat(
    reconnect ? [`reconnect.${b64url(reconnect)}`] : [],
  );
  // SELF.fetch requires http(s):// — convert wss:// to https:// for the test harness.
  const httpUrl = wsUrl.replace(/^wss:\/\//, "https://").replace(/^ws:\/\//, "http://");
  const res = await SELF.fetch(httpUrl, {
    headers: { upgrade: "websocket", "sec-websocket-protocol": protos.join(", ") },
  });
  if (res.status !== 101 || !res.webSocket) throw new Error(`upgrade failed: ${res.status}`);
  res.webSocket.accept();
  return res.webSocket;
}

export function nextMsg(ws: WebSocket, predicate?: (m: any) => boolean): Promise<any> {
  return new Promise((resolve, reject) => {
    const onMsg = (e: MessageEvent) => {
      const m = JSON.parse(String(e.data));
      if (!predicate || predicate(m)) {
        ws.removeEventListener("message", onMsg as any);
        resolve(m);
      }
    };
    ws.addEventListener("message", onMsg as any);
    setTimeout(() => reject(new Error("timeout")), 2_000);
  });
}

export function send(ws: WebSocket, msg: object) {
  ws.send(JSON.stringify({ v: 1, ...msg }));
}
