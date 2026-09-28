import { z } from "zod";
import { MAX_SYNC_FRAME_BYTES } from "@rishi/sharing-protocol/sync";

/**
 * Frozen inbound /v1 validation from
 * origin/main:packages/sharing-protocol/src/schemas.ts.
 *
 * The shared protocol now applies stricter Apple /v2 wire validation. Keep
 * these legacy entry points compatible with clients released against /v1;
 * changes to the current protocol must not silently tighten this boundary.
 */
const Base = z.object({ v: z.literal(1) });
export const MAX_LEGACY_RAW_FRAME_BYTES = 64 * 1024;
const UserId = z.string().min(1).max(64);
const sha256HexSchema = z
  .string()
  .regex(/^[0-9a-f]{64}$/, "contentHash must be lowercase sha256 hex (64 chars)");

// Preserve the original /v1 frame shape while bounding the payload that the
// server may fan out to every peer. The current shared SyncFrame schema has
// stricter fields than some released /v1 clients used.
const LegacySyncFrame = z.unknown().refine((frame) => {
  try {
    const encoded = JSON.stringify(frame);
    return encoded !== undefined && new TextEncoder().encode(encoded).byteLength <= MAX_SYNC_FRAME_BYTES;
  } catch {
    return false;
  }
}, { message: "sync frame exceeds the 16 KiB maximum" });

export const ClientMsg = z.discriminatedUnion("t", [
  Base.extend({ t: z.literal("hello"), hasBookFile: z.boolean() }),
  Base.extend({ t: z.literal("sdp.offer"), to: UserId, sdp: z.string().max(20_000) }),
  Base.extend({ t: z.literal("sdp.answer"), to: UserId, sdp: z.string().max(20_000) }),
  Base.extend({ t: z.literal("ice"), to: UserId, candidate: z.unknown() }),
  Base.extend({ t: z.literal("request.sharer") }),
  Base.extend({ t: z.literal("pass.sharer"), to: UserId }),
  Base.extend({ t: z.literal("mute.peer"), userId: UserId, muted: z.boolean() }),
  Base.extend({ t: z.literal("kick.peer"), userId: UserId }),
  Base.extend({ t: z.literal("approve.join"), userId: UserId }),
  Base.extend({ t: z.literal("reject.join"), userId: UserId }),
  Base.extend({ t: z.literal("has.book"), value: z.boolean() }),
  Base.extend({ t: z.literal("mic.state"), value: z.enum(["unmuted", "self-muted"]) }),
  Base.extend({ t: z.literal("leave") }),
  Base.extend({ t: z.literal("ping") }),
  Base.extend({ t: z.literal("sync.frame"), frame: LegacySyncFrame }),
  Base.extend({
    t: z.literal("data.channel.relay"),
    to: UserId,
    channel: z.enum(["sync", "files"]),
    payload: z.string(),
  }),
]);
export type ClientMsg = z.infer<typeof ClientMsg>;

const BookContext = z.object({
  bookId: z.string(),
  contentHash: sha256HexSchema,
  format: z.enum(["epub", "pdf"]),
});

export const CreateSessionBody = z.object({
  bookContext: BookContext,
  requiresApproval: z.boolean(),
});

export const RedeemBody = z.object({ joinToken: z.string().min(10) });
