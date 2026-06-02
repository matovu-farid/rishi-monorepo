import { z } from "zod";

const Base = z.object({ v: z.literal(1), ts: z.number() });
const BookId = z.string().min(1).max(128);

/**
 * Reader position is FORMAT-NATIVE — PDF uses page + pixel offsetY within
 * page, EPUB uses CFI only. epub-js advances by spine/CFI; there is no
 * shared "scrollY" because the two readers have incompatible position
 * spaces.
 */
export const ReaderPosition = z.discriminatedUnion("format", [
  z.object({
    format: z.literal("pdf"),
    page: z.number().int().nonnegative(),
    offsetY: z.number(),
    ts: z.number(),
  }),
  z.object({
    format: z.literal("epub"),
    cfi: z.string().min(1),
    ts: z.number(),
  }),
]);
export type ReaderPosition = z.infer<typeof ReaderPosition>;

export const SyncMsg = z.discriminatedUnion("t", [
  Base.extend({
    t: z.literal("reader.position"),
    bookId: BookId,
    position: ReaderPosition,
  }),
  Base.extend({
    t: z.literal("tts.state"),
    isPlaying: z.boolean(),
    position: z.object({ sentenceIdx: z.number().int(), charOffset: z.number().int() }),
    voiceId: z.string(),
    rate: z.number(),
  }),
  Base.extend({
    t: z.literal("annotation.add"),
    id: z.string(),
    range: z.unknown(),
    color: z.string(),
  }),
  Base.extend({ t: z.literal("annotation.remove"), id: z.string() }),
  Base.extend({ t: z.literal("cursor"), x: z.number(), y: z.number() }),
  Base.extend({
    t: z.literal("snapshot"),
    bookId: BookId,
    position: ReaderPosition.optional(),
    tts: z.unknown().optional(),
  }),
]);
export type SyncMsg = z.infer<typeof SyncMsg>;
