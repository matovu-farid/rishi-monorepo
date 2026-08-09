import type { ApnsSender } from "../billing/apns";

export type ShareNotificationDevice = {
  deviceToken: string;
  topic: string;
  env: string;
};

export type ShareNotificationDeps = {
  apns: ApnsSender | null;
  findDevicesByUserId: (userId: string) => Promise<ShareNotificationDevice[]>;
};

export async function emitShareCreatedPush(
  deps: ShareNotificationDeps,
  args: { recipientUserId: string; packageId: string; bookCount: number },
): Promise<void> {
  if (!deps.apns) return;

  const devices = await deps.findDevicesByUserId(args.recipientUserId);
  const bookLabel = args.bookCount === 1 ? "book" : "books";
  for (const device of devices) {
    try {
      await deps.apns.sendAlertPush({
        deviceToken: device.deviceToken,
        topic: device.topic,
        env: device.env,
        title: "New books shared with you",
        body: `${args.bookCount} ${bookLabel} were shared with you.`,
        payload: {
          rishi: {
            kind: "share.created",
            package_id: args.packageId,
          },
        },
      });
    } catch (error) {
      console.error("share notification push failed", {
        recipientUserId: args.recipientUserId,
        deviceToken: device.deviceToken,
        error,
      });
    }
  }
}
