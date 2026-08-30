import { describe, expect, it, vi } from "vitest";
import { generateTurnIceServers } from "../src/turn";

describe("Cloudflare ICE credentials", () => {
  it("uses Cloudflare STUN when relay credentials are not configured", async () => {
    await expect(generateTurnIceServers({})).resolves.toEqual([
      { urls: ["stun:stun.cloudflare.com:3478"] },
    ]);
  });

  it("filters unsupported ICE URLs from Cloudflare responses", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478", "https://not-ice.example"] },
        { urls: ["turns:turn.cloudflare.com:443"], username: "u", credential: "c" },
      ],
    }), { status: 201 })));

    await expect(generateTurnIceServers({ TURN_KEY_ID: "key", TURN_API_TOKEN: "token" })).resolves.toEqual([
      { urls: ["stun:stun.cloudflare.com:3478"] },
      { urls: ["turns:turn.cloudflare.com:443"], username: "u", credential: "c" },
    ]);
  });
});
