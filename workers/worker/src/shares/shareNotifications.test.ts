import { describe, expect, it, vi } from "vitest";

import { emitShareCreatedPush } from "./shareNotifications";

describe("share notifications", () => {
  it("sends a share-created alert to every registered recipient device", async () => {
    const sendAlertPush = vi.fn(async () => undefined);

    await emitShareCreatedPush({
      apns: { sendAlertPush } as never,
      findDevicesByUserId: vi.fn(async () => [
        { deviceToken: "token-a", topic: "org.fidexa.rishi", env: "production" },
        { deviceToken: "token-b", topic: "org.fidexa.rishi", env: "production" },
      ]),
    }, {
      recipientUserId: "recipient-1",
      packageId: "package-1",
      bookCount: 2,
    });

    expect(sendAlertPush).toHaveBeenCalledTimes(2);
    expect(sendAlertPush).toHaveBeenCalledWith(expect.objectContaining({
      deviceToken: "token-a",
      title: "New books shared with you",
      body: "2 books were shared with you.",
      payload: { rishi: { kind: "share.created", package_id: "package-1" } },
    }));
  });

  it("continues fan-out when one device rejects the push", async () => {
    const sendAlertPush = vi.fn()
      .mockRejectedValueOnce(new Error("APNs rejected device"))
      .mockResolvedValueOnce(undefined);

    await expect(emitShareCreatedPush({
      apns: { sendAlertPush } as never,
      findDevicesByUserId: async () => [
        { deviceToken: "token-a", topic: "org.fidexa.rishi", env: "production" },
        { deviceToken: "token-b", topic: "org.fidexa.rishi", env: "production" },
      ],
    }, {
      recipientUserId: "recipient-1",
      packageId: "package-1",
      bookCount: 1,
    })).resolves.toBeUndefined();

    expect(sendAlertPush).toHaveBeenCalledTimes(2);
  });
});
